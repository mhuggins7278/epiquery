tedious     = require 'tedious'
path        = require 'path'
express     = require 'express'
fs          = require 'fs'
dot         = require 'dot'
util        = require 'util'
_           = require 'underscore'
Q           = require 'q'
crypto      = require 'crypto'
mysql       = require 'mysql'
hogan       = require 'hogan.js'
http        = require 'http'
xmla        = require 'xmla4js'
log         = require 'simplog'
durations   = require('./utils.coffee')
durations   = new durations.DurationTracker()
os          = require 'os'
cluster     = require 'cluster'
jwt         = require 'express-jwt'


config =
  sql:
    userName: process.env.EPIQUERY_SQL_USER
    password: process.env.EPIQUERY_SQL_PASSWORD
    server:   process.env.EPIQUERY_SQL_SERVER
    options:
      port:   process.env.EPIQUERY_SQL_PORT
  sql_ro:
    userName: process.env.EPIQUERY_SQL_RO_USER
    password: process.env.EPIQUERY_SQL_RO_PASSWORD
    server:   process.env.EPIQUERY_SQL_SERVER
    options:
      port:   process.env.EPIQUERY_SQL_PORT
  mysql:
    host:     process.env.EPIQUERY_MYSQL_SERVER
    user:     process.env.EPIQUERY_MYSQL_USER
    password: process.env.EPIQUERY_MYSQL_PASSWORD
    multipleStatements: true
  mysql_ro:
    host:     process.env.EPIQUERY_MYSQL_SERVER
    user:     process.env.EPIQUERY_MYSQL_RO_USER
    password: process.env.EPIQUERY_MYSQL_RO_PASSWORD
    multipleStatements: true
  mdx:
    userName: process.env.EPIQUERY_MDX_USER
    password: process.env.EPIQUERY_MDX_PASSWORD
    server:   process.env.EPIQUERY_MDX_SERVER
    url:      process.env.EPIQUERY_MDX_URL
    catalog:  process.env.EPIQUERY_MDX_CATALOG
  mdx_ro:
    userName: process.env.EPIQUERY_MDX_USER
    password: process.env.EPIQUERY_MDX_PASSWORD
    server:   process.env.EPIQUERY_MDX_SERVER
    url:      process.env.EPIQUERY_MDX_URL
    catalog:  process.env.EPIQUERY_MDX_CATALOG
  template_directory: process.env.EPIQUERY_TEMPLATE_DIRECTORY
  http_port: process.env.EPIQUERY_HTTP_PORT
  status_dir: process.env.EPIQUERY_STATUS_DIR || '/dev/shm'
  worker_count: process.env.EPIQUERY_WORKER_COUNT || os.cpus().length
  jwt_secret: process.env.JWT_SECRET

# yes, this is a global variable we use it to track our requests so we can
# create unique identifiers per request
request_counter = 0

#regex to replace MS special charactes
special_characters = {
  "8220": {"regex": new RegExp(String.fromCharCode(8220), "gi"), "replace": '"'} # “
  ,"8221": {"regex": new RegExp(String.fromCharCode(8221), "gi"), "replace": '"'} # ”
  ,"8216": {"regex":  new RegExp(String.fromCharCode(8216), "gi"), "replace": "'"} # ‘
  ,"8217": {"regex": new RegExp(String.fromCharCode(8217), "gi"), "replace": "'"} # ’
  ,"8211": {"regex": new RegExp(String.fromCharCode(8211), "gi"), "replace": "-"} # –
  ,"8212": {"regex": new RegExp(String.fromCharCode(8212), "gi"), "replace": "--"} # —
  ,"189": {"regex": new RegExp(String.fromCharCode(189), "gi"), "replace": "1/2"} # ½
  ,"188": {"regex": new RegExp(String.fromCharCode(188), "gi"), "replace": "1/4"} # ¼
  ,"190": {"regex": new RegExp(String.fromCharCode(190), "gi"), "replace": "3/4"} # ¾
  ,"169": {"regex": new RegExp(String.fromCharCode(169), "gi"), "replace": "(C)"} # ©
  ,"174": {"regex": new RegExp(String.fromCharCode(174), "gi"), "replace": "(R)"} # ®
  ,"8230": {"regex": new RegExp(String.fromCharCode(8230), "gi"), "replace": "..."} # …
}

# we support the ability to specify your connection details in the
# request, this allows us to pull the correct connection info
get_connection_config = (req, db_type) ->
  conn_header = req.get "X-DB-CONNECTION"
  if conn_header
    return JSON.parse conn_header
  else
    # can write on POST, all others read only
    if req.method is "POST"
      return config[db_type]
    else
      return config["#{db_type}_ro"]

# a helper method to handle escaping of values for SQL Server
# to avoid the evil SQL Injection....
escape_for_tsql = (value) ->
  if isNaN value
    if _.isString value
      _.each Object.keys(special_characters), (key) ->
        value = value.replace special_characters[key].regex,special_characters[key].replace
      return value.replace(/'/g, "''")
    else if _.isArray value
      return _.map value, (item) -> escape_for_tsql item
    else if _.isObject value
      _.each value, (v,k,o) -> o[k] = escape_for_tsql v
      return value
  return value

##########################################################
# <template rendering>

# whitespace is important, we don't want to strip it
dot.templateSettings.strip = false

# keep track of our renderers, we're storing them by
# their associated file extension as that is how we'll
# be looking them up
renderers = {}
renderers[".dot"] =  (template_string, context) ->
  templateFn = dot.template template_string
  templateFn context

renderers[".mustache"] =  (template_string, context) ->
  template = hogan.compile template_string
  template.render context

# this is purely to facilitate testing
renderers[".error"] = () ->
  pants_are cool
  throw "pants"

# set our default handler, which does nothing
# but return the template_string it was given
renderers[""] = (template_string) ->
  template_string

get_renderer_for_template = (template_path) ->
  renderer = renderers[path.extname template_path]
  # hava 'default' renderer for any unrecognized extensions
  if renderer
    return renderer
  else
    return renderers[""]

# </template rendering>
##########################################################

##########################################################
# <script decoration>
# we're making a rest like interface here and as such we're
# gonna enforce read only behavior on GETs and not on POSTs
# we're also gonna provide some general help like setting an implicit
# READ UNCOMMITTED on GETs because 99.99999999 percent of the time
# that's what you want.  These changes based on rest-y GET or POST
# request types will be handled by the handlers defined here which
# will change the string that we ultimately send to the server
prefix_handlers =
  mssql:
    get:  (sql) -> ""
    post: (sql) -> ""
    head: (sql) -> ""
  mysql:
    get:  (sql) -> "SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;\n"
    post: (sql) -> ""
    head: (sql) -> "SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;\n"
  mdx:
    get:  (sql) -> ""
    post: (sql) -> ""
    head: (sql) -> ""

suffix_handlers =
  mssql:
    get:  (sql) -> ""
    post: (sql) -> ""
    head: (sql) -> ""
  mysql:
    get:  (sql) -> ""
    post: (sql) -> ""
    head: (sql) -> ""
  mdx:
    get:  (sql) -> ""
    post: (sql) -> ""
    head: (sql) -> ""

decorate_mssql_script = (request_type, sql) ->
  t = request_type.toLowerCase()
  "#{prefix_handlers.mssql[t](sql)}#{sql}#{suffix_handlers.mssql[t](sql)}"

decorate_mysql_script = (request_type, sql) ->
  t = request_type.toLowerCase()
  "#{prefix_handlers.mysql[t](sql)}#{sql}#{suffix_handlers.mysql[t](sql)}"
# </script decoration>
##########################################################

log_promise = (name, promise) ->
  log.debug JSON.stringify({
      name: name
     ,isFulfilled: promise.isFulfilled()
     ,isPending: promise.isPending()
     ,isRejected: promise.isRejected()
    })

exec_sql_query = (req, template_name, template_context, callback) ->
  result_sets = []
  row_data = null
  connect_deferred           = Q.defer()
  connect_end_deferred       = Q.defer()
  template_loaded_deferred   = Q.defer()
  request_complete_deferred  = Q.defer()
  rendered_template          = undefined

  conn = new tedious.Connection get_connection_config(req, 'sql')
  conn.on 'errorMessage', (message) ->
    log.error "On request #{req.path} with error #{JSON.stringify(message)}"
  conn.on 'connect', connect_deferred.makeNodeResolver()
  conn.on 'end', () -> connect_end_deferred.resolve()

  # need to read our template to get the contents
  fs.readFile(
    path.join(path.normalize(config.template_directory), template_name),
    {encoding:'utf8'},
    template_loaded_deferred.makeNodeResolver())

  # once we have a connection and our template contents, then we can continue
  Q.all([template_loaded_deferred.promise, connect_deferred.promise]).spread(
    # a resolved connect has no arguments so we'll get our template argument first
    (template) ->
      renderer = get_renderer_for_template template_name
      log.debug "raw template: #{template}"
      rendered = renderer template.toString(), template_context
      rendered_template = rendered
      log.debug "template context: #{JSON.stringify(template_context)}"
      log.debug "rendered template(type #{typeof rendered})\n #{rendered}"
      request = new tedious.Request(rendered, request_complete_deferred.makeNodeResolver())
      # make sure that no matter how our request-complete event ends, we close the connection
      request_complete_deferred.promise.finally () -> conn.close()
      request_complete_deferred.promise.then () ->
        if row_data isnt null
          result_sets.push(row_data)
        log.event "request-completed #{arguments[0]}, #{arguments[1]}"
      # <for debugging>
      request.on 'done', () -> a=arguments; log.event("done #{a[0]}, #{a[1]}, #{a[2]}")
      request.on 'columnMetadata', () -> log.event("columnMetadata")
      request.on 'doneProc', () -> a=arguments; log.event("doneProc #{a[0]}, #{a[1]}, #{a[2]}, #{a[3]}")
      request.on 'doneInProc', () -> a=arguments; log.event("doneInProc #{a[0]}, #{a[1]}, #{a[2]}")
      # </for debugging>

      # we use this event to split up multipe result sets as each result set
      # is preceeded by a columnMetadata event
      request.on 'columnMetadata', () ->
        # first time through we should have a null value
        # after that we'll either have empty arrays or some data to
        # push onto our result sets
        if row_data isnt null
          result_sets.push(row_data)
        row_data = []
      # collecting our results, yes .4 of tedious allows this to be collected
      # on the request callback, this just didn't get converted for the new version
      request.on 'row', (columns) -> log.event "row" ; row_data.push(columns)
      # we're _just_ rendering strings to send to sql server so batch is really
      # what we want here, all that fancy parameterization and 'stuff' is done in
      # the template
      conn.execSqlBatch request
  ).fail (error) -> callback error, result_sets, rendered_template # something in the spread failed

  connect_end_deferred.promise.then () ->
    # this is silly, but... there's a case where tedious will fail to
    # connect but not raise a connect(err) event instead going straight to
    # raising 'end'.  So from the normal processing path, this should be
    # raised by the close of the connection which is done on the request-complete
    # trigger and we should then be done anyway so this will simply be redundant
    log.event 'connect_end'
    if connect_deferred.promise.isPending()
      connect_deferred.reject('connection ended prior to sucessful connect')

  Q.all([
    connect_deferred.promise,
    connect_end_deferred.promise,
    template_loaded_deferred.promise,
    request_complete_deferred.promise
  ]).then(
    () -> callback null, result_sets, rendered_template
  ).fail( (error) ->
    log.error "raw template: #{template_name}, template context: #{JSON.stringify(template_context)}"
    log.error error
    try
      callback error, result_sets, rendered_template
    catch e
      log.error e
  ).finally( () ->
      log_promise 'connect', connect_deferred.promise,
      log_promise 'connect_end', connect_end_deferred.promise,
      log_promise 'template_loaded', template_loaded_deferred.promise,
      log_promise 'request_complete', request_complete_deferred.promise
  ).done()

exec_mysql_query = (req, template_name, template_context, callback) ->
  log.debug "exec_mysql_query"
  connect_deferred = Q.defer()
  request_deferred = Q.defer()

  log.info "using template: #{template_name}"
  template_loaded = Q.nfcall(fs.readFile,
    path.join(path.normalize(config.template_directory), template_name),
    {encoding:'utf8'})

  conn = mysql.createConnection get_connection_config(req, 'mysql')
  conn.connect connect_deferred.makeNodeResolver()
  conn.on 'error', (error) -> callback error, null
  rendered_template = ""

  Q.all([template_loaded, connect_deferred.promise]).spread( (template) ->
    renderer = get_renderer_for_template template_name
    log.debug "raw template: #{template}"
    rendered_template = renderer template.toString(), template_context
    rendered_template = decorate_mysql_script req.method, rendered_template
    log.debug "template context: #{JSON.stringify(template_context)}"
    log.debug "rendered template\n #{rendered_template}"
    conn.query rendered_template, request_deferred.makeNodeResolver()
  ).fail((error) ->
    log.error "template context: #{JSON.stringify(template_context)}"
    log.error "rendered template\n #{rendered_template}"
    callback error, null
  ).finally( () -> conn.end() )

  Q.all([
    template_loaded,
    request_deferred.promise,
    connect_deferred.promise]
  ).spread(
    (template, rows, connect) ->
      # no docs yet found for this, but apparently the response is at
      # least a two-part thing where the first item is the actual
      # response, the second part is metadata
      callback null, rows[0]
  ).fail(
    (error) -> callback error, null
  ).finally( () ->
    log_promise 'connect', connect_deferred.promise
    log_promise 'template_loaded', template_loaded
    log_promise 'request', request_deferred.promise
  ).done()

exec_mdx_query = (req, template_name, template_context, callback) ->
  conf = get_connection_config(req, 'mdx')
  #format is a analysis installation our installation is multidimensional so hardcoding for now
  format = xmla.Xmla.PROP_FORMAT_MULTIDIMENSIONAL

  Q.nfcall(fs.readFile,
     path.join(path.normalize(config.template_directory), template_name),
     {encoding:'utf8'}
  ).then( (template) ->
    Q.try( () ->
      renderer = get_renderer_for_template template_name
      log.debug "raw template: #{template}"
      rendered_template = renderer template.toString(), template_context
      log.info "rendered template(type #{typeof rendered_template})\n #{rendered_template}"
      xmlaRequest =
        async: true
        url: conf.url
        success: (xmla, xmlaRequest, xmlaResponse) ->
          Q.try(() ->
            if(!xmlaResponse)
               log.error('MDX query succeeded '+ template_name + ' but response from xmlarequest is undefined')
               callback 'ERROR:  MDX query succeeded '+ template_name + ' but response from xmlarequest is undefined', null
            else
               obj =  xmlaResponse.fetchAsObject()
               if(obj == false)
                 output = JSON.stringify({})
               else
                 output = JSON.stringify(obj)
               callback null, output
          ).catch( (error) ->
            log.error('MDX query succeeded error parsing response as object (xmlaResponse.fetchAsObject())' + error)
            log.error('MDX response=' + xmlaResponse)
            callback 'MDX query succeeded.  error parsing response (fetch as object to json).  ' + error, null
          )
        error: (xmla, xmlaRequest, exception) ->
          log.error('MDX query failed to execute, exception=' + exception.message)
          callback exception.message, null

      xmlaRequest.properties = {}
      xmlaRequest.properties[xmla.Xmla.PROP_CATALOG] = conf.catalog
      xmlaRequest.properties[xmla.Xmla.PROP_FORMAT] = format
      xmlaRequest.properties[xmla.Xmla.PROP_DATASOURCEINFO] = conf.server
      xmlaRequest.method = xmla.Xmla.METHOD_EXECUTE
      xmlaRequest.statement =  rendered_template
      x = new xmla.Xmla()
      x.request(xmlaRequest)
    ).catch( (error) ->
      log.error('MDX query call failure, error calling analysis server ' + conf.url + ' template='+template_name + ', error='+error)
      callback 'MDX, Error calling analysis server  error='+ error, null)
  , (error) ->
    log.error('MDX query failed to load template error=' + error)
    callback error, null
  ).done()

# here we will create a full path to the file that will be used to store any
# status about a currently executing request so this will return a path that
# should be unique to a request running in the process handling
create_status_path = (template_path) ->
    hasher = crypto.createHash 'sha1'
    hasher.update template_path
    hasher.update "#{new Date().getTime()}"
    hasher.update "#{request_counter++}"
    hasher.update "#{process.pid}"
    path.normalize path.join(config.status_dir, "#{process.pid}.#{hasher.digest('hex')}")

request_handler = (req, resp) ->
  # combining the body and query so they can be use for the context of the template render
  context = _.extend {}, req.body, req.query, req.headers

  log.info "Url: #{req.path}, Context: #{JSON.stringify(context)}"

  isMySQLRequest = false
  isMDXRequest = false

  # we allow people to provide any path relative to the templates directory
  # so we'll remove initial /'s and keep the rest of the path while conveniently
  # dropping any parent indicators (..)
  template_path = req.path[1..].replace(/\.\./g, '')

  while template_path[0] is '/'
    template_path = template_path[1..]

  # initialize our request status path variable so we can use it later, more
  # importantly, if so configured, save out status data for the current request
  # for debugging purposes
  # So, there should have never been sockets in here, it's just dumb... but
  # there are and we're not gonna bother to do this with inbound socket requests
  # because no one really uses them and there's no point
  req_status_path = undefined
  if config.status_dir
    req_status_path = create_status_path(template_path)
    status_data = "#{template_path}\nStarted At: #{new Date()}\n"
    fs.writeFileSync req_status_path, status_data
    remove_status_data = () ->
      fs.unlink req_status_path, (err) ->
        if err
          log.error "error removing status file #{req_status_path}, #{err}"
    resp.on 'close', remove_status_data
    resp.on 'finish', remove_status_data

  log.info "raw template path: #{template_path}"
  if template_path.indexOf("mysql") isnt -1
    isMySQLRequest = true
  else if template_path.indexOf("mdx") isnt -1
    isMDXRequest = true
  log.debug "working template path: #{template_path}"
  durationTracker = durations.start template_path


  create_error_response = (error, resp, template_path, template_context, rendered_template) ->
    resp.statusCode = 500
    result = {status: "error"}
    if typeof(error) is "string"
      result.message = error
    else
      result.message = error.message
      log.error "#{error.message}\n#{error.stack}\nTemplate:\n  #{template_path}\n\nContext:\n  #{JSON.stringify(template_context)}"
    if typeof(rendered_template) isnt undefined
      result.rendered_template = rendered_template
    # try and avoid giving too much away in our error message
    result.message = result.message.replace process.cwd(), ""
    result

  run_query = (req, resp, template_path, context) ->
    if isMySQLRequest
      log.info "processing mysql query"
      exec_mysql_query req, template_path, context, (error, rows) ->
        log.info "[EXECUTION STATS] template: '#{template_path}', duration: #{durationTracker.stop()}ms"
        if error
          resp.respond create_error_response(error, resp, template_path, context)
        else
          resp.respond rows
    else if isMDXRequest
      log.info "processing mdx query"
      exec_mdx_query req, template_path, context, (error, rows) ->
        log.info "[EXECUTION STATS] template: '#{template_path}', duration: #{durationTracker.stop()}ms"
        if error
          resp.respond create_error_response(error, resp, template_path, context)
        else
          resp.respond rows
    else
      log.info "processing T-SQL query"
      # escape things so nothing nefarious gets by
      _.each context, (v, k, o) -> o[k] = escape_for_tsql(v)
      exec_sql_query req, template_path, context, (error, rows, rendered_template) ->
        log.info "[EXECUTION STATS] template: '#{template_path}', duration: #{durationTracker.stop()}ms"
        if error
          resp.respond create_error_response(error, resp, template_path, context, rendered_template)
        else
          log.debug "Result Set: #{JSON.stringify(rows)}"
          if rows.length > 1 # we have multiple result sets
            log.debug "#{rows.length}(s) result sets returned"
            row_count = 0
            result = []
            for result_set in rows
              row_count += result_set.length
              result.push _.map result_set, (columns) ->
                _.object _.map columns, (column) ->
                  [column.metadata.colName, column.value]
            log.info "#{row_count}(s) rows returned, raw template path: #{template_path}"

          else
            log.debug "1 result set returned"
            row_count = 0
            if rows[0]
              row_count = rows[0].length
            result = _.map rows[0], (columns) ->
              _.object _.map columns, (column) ->
                [column.metadata.colName, column.value]
            log.info "#{row_count}(s) rows returned, raw template path: #{template_path}"
          resp.respond result

  # check to see if we're running a 'development' request which is a
  # request with a template included within, as opposed to referecing
  # an existing template on disk
  if context["__template"]
    hasher = crypto.createHash 'sha1'
    hasher.update context["__template"]
    template_type = context["__template_type"] || "mustache"
    temp_template_path = "debug/#{hasher.digest('hex')}.#{template_type}"
    temp_file_path = path.join(path.normalize(config.template_directory), temp_template_path)
    log.debug "writing template contents to tmp file at #{temp_file_path}"
    fs.writeFile temp_file_path, context["__template"], (err) ->
      if err
        log.error "error writing debug template for dynamic request #{err}"
      else
        run_query req, resp, temp_template_path, context
  else
    # normal query path
    run_query req, resp, template_path, context

request_helper = (req, resp) ->
  if req.query['callback']
    resp.respond = () ->
      resp.jsonp.apply(resp, _.toArray(arguments))
  else
    resp.respond = resp.send
  request_handler req, resp

app = express()
app.use express.bodyParser()
app.use(jwt({secret: config.jwt_secret}).unless({path: ['/diagnostic']}))
app.get '/stats', (req, resp, next) ->
  stats=
    runningQueries: durations.getRunningItems()
    longestRunningQueryInstance: durations.getLongestDurations()
    durationForLastExecution: durations.getCompletedItems()
    executionByTemplate: durations.startCounts
    totalStarts: durations.totalStarts
    totalStops: durations.totalStops
  resp.send stats
app.get '*', request_helper
app.post '*', request_helper
app.head '*', (req, resp) ->
  resp.send ''

if cluster.isMaster
  fork_worker = () ->
    worker = cluster.fork()
    worker.once 'exit', (code, signal) ->
      log.error "worker died with error code #{code} and signal #{signal}"
      if signal isnt "SIGTERM"
        fork_worker()

  log.info "Starting epi server on port: #{config.http_port}"
  log.debug "Debug logging enabled"
  log.info durations
  log.info "Configuration: #{JSON.stringify config}"
  [ fork_worker() for i in [1..config.worker_count] ]
else
  log.info "worker starting on port #{config.http_port}"
  # if we don't have a status dir set ( it must exist )
  # then we'll drop the status_dir value since we'll later use it as a flag
  # to determine if we shold log status
  if ( !fs.existsSync(config.status_dir) )
    delete(config.status_dir)
  else
    # create our status directory if it's not there, race condition understood sir
    config.status_dir = path.join(config.status_dir, "epiquery_status")
    fs.mkdirSync(config.status_dir) unless ( fs.existsSync(config.status_dir) )
  server = http.createServer app
  server.listen config.http_port
