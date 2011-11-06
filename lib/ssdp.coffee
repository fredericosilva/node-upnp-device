dgram = require 'dgram'
url = require 'url'
http = require 'http'
config = require './config'
device = require './device'
extend = require('./helpers').extend

announce = exports.announce = (dev, httpServer) ->
    advertise dev, httpServer
    # recommended delay between advertisements is a random interval of less than half of timeout
    setInterval(
        advertise
        Math.floor(Math.random() * ((config.ssdp.timeout / 2) * 1000))
        dev, httpServer
    )

listen = exports.listen = (dev, httpServer) ->
    socket = dgram.createSocket 'udp4', (msg, rinfo) ->
        parseHeaders msg, (err, req) ->
            # these are the ST (search type) values we should respond to
            respondTo = [ 'ssdp:all', 'upnp:rootdevice', config.uuid ]
            if req.method is 'M-SEARCH' and req.headers.st in respondTo
                # specification says to wait between 0 and MX
                # (max 120) seconds before responding
                wait = Math.floor(Math.random() * (parseInt(req.headers.mx) + 1))
                wait = if wait >= 120 then 120 else wait
                setTimeout(
                    answer, wait
                    searchType: req.headers.st, address: rinfo.address, port: rinfo.port
                    dev, httpServer
                )
    socket.addMembership config.ssdp.address
    socket.bind config.ssdp.port

advertise = (dev, httpServer) ->
    sendMessages(
        makeMessage(
            'notify'
            nt: nt, nts: 'ssdp:alive', host: null
            dev, httpServer
        ) for nt in makeNotificationHeaders(dev)
    )

answer = (req, dev, httpServer) ->
    # unless ssdp:all, respond once with same search type as request's
    sendMessages(
        makeMessage(
            'ok'
            st: st, ext: null
            dev, httpServer
        ) for st in (if req.searchType is 'ssdp:all' then makeNotificationHeaders(dev) else [ req.searchType ])
        req.address
        req.port
    )

# send 3 messages about the device, and then one for each service
makeNotificationHeaders = (dev) ->
    arr = [ 'upnp:rootdevice', config.uuid, device.makeDeviceType(dev.type) ]
    for serviceType in config.devices[dev.type].services
        arr.push device.makeServiceType(serviceType)
    arr

# create a UDP socket, send messages, then close socket
sendMessages = (messages, address, port) ->
    port ?= config.ssdp.port
    socket = dgram.createSocket 'udp4'
    if address?
        socket.setTTL 4
        socket.setMulticastTTL 4
        socket.addMembership config.ssdp.address
    else
        address = config.ssdp.address
    socket.bind(config.ssdp.port)
    done = messages.length
    console.log "Sent messages to #{address}:#{port}"
    for msg in messages
        socket.send msg, 0, msg.length, port, address, ->
            if done-- is 1
                socket.close()

# generate SSDP (HTTPU/HTTPMU) headers suiting the message type
makeMessage = (reqType, customHeaders, dev, httpServer) ->
    # headers with static values
    defaultHeaders =
        host: "#{config.ssdp.address}:#{config.ssdp.port}"
        'cache-control': "max-age = #{config.ssdp.timeout}"
        location: makeDescriptionUrl httpServer
        server: makeServerString dev
        ext: ''
        usn: config.uuid + (if config.uuid in [ customHeaders.nt, customHeaders.st ] then '' else '::' + customHeaders.nt or customHeaders.st)

    # headers that are always used
    includeHeaders = [ 'cache-control', 'server', 'usn', 'location' ]
    # add passed headers to list of headers to include
    for key of customHeaders
        includeHeaders.push key

    # build message string
    message =
        if reqType is 'ok'
            [ "HTTP/1.1 200 OK" ]
        else
            [ "#{reqType.toUpperCase()} * HTTP/1.1" ]

    for header in includeHeaders
        message.push "#{header.toUpperCase()}: #{customHeaders[header] or defaultHeaders[header]}"

    # add carriage returns and new lines as required by HTTP spec
    message.push '\r\n'
    console.log message
    new Buffer message.join '\r\n'

makeServerString = (dev) ->
    [ "OS/1.0"
      "UPnP/1.0"
      "#{dev.name}/1.0"
    ].join ' '

makeDescriptionUrl = (s) ->
    url.format(
        protocol: 'http:'
        hostname: s.address
        port: s.port
        pathname: '/device/description'
    )

# parse headers using http module parser
parseHeaders = (msg, callback) ->
    parser = http.parsers.alloc()
    parser.reinitialize('request')
    parser.onIncoming = (req) ->
        http.parsers.free(parser)
        callback null, req
    parser.execute msg, 0, msg.length