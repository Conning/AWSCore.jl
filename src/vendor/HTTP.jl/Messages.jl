module Messages

export Message, Request, Response, Body,
       method, iserror, isredirect, parentcount, isstream, isstreamfresh,
       header, setheader, defaultheader, setlengthheader,
       waitforheaders, wait,
       writeandread

import ..HTTP

include("Bodies.jl")
using .Bodies

using ..IOExtras
using ..Pairs
using ..Parsers
import ..Parsers
import ..ConnectionPool

import ..@debug, ..DEBUG_LEVEL


"""
    Request

Represents a HTTP Request Message.

- `method::String`
- `uri::String`
- `version::VersionNumber`
- `headers::Vector{Pair{String,String}}`
- `body::`[`HTTP.Body`](@ref)
- `parent::Response`, the `Response` (if any) that led to this request
  (e.g. in the case of a redirect).
"""

mutable struct Request
    method::String
    uri::String
    version::VersionNumber
    headers::Vector{Pair{String,String}}
    body::Body
    parent
end

Request() = Request("", "")
Request(method::String, uri, headers=[], body=Body(); parent=nothing) =
    Request(method, uri == "" ? "/" : uri, v"1.1",
            mkheaders(headers), body, parent)

Request(bytes) = read!(IOBuffer(bytes), Request())
Base.parse(::Type{Request}, str::AbstractString) = Request(str)

mkheaders(v::Vector{Pair{String,String}}) = v
mkheaders(x) = [string(k) => string(v) for (k,v) in x]


"""
    Response

Represents a HTTP Response Message.

- `version::VersionNumber`
- `status::Int16`
- `headers::Vector{Pair{String,String}}`
- `body::`[`HTTP.Body`](@ref)
- `complete::Condition`, raised when the `Parser` has finished
   reading the Response Headers. This allows the `status` and `header` fields
   to be read used asynchronously without waiting for the entire body to be
   parsed.
   `complete` is also raised when the entire Response Body has been read.
- `exception`, set if `writeandread` fails.
- `parent::Request`, the `Request` that yielded this `Response`.
"""

mutable struct Response
    version::VersionNumber
    status::Int16
    headers::Vector{Pair{String,String}}
    body::Body
    complete::Condition
    exception
    parent
end

Response(status::Int=0, headers=[]; body=Body(), parent=nothing) =
    Response(v"1.1", status, headers, body, Condition(), nothing, parent)

Response(bytes) = read!(IOBuffer(bytes), Response())
Base.parse(::Type{Response}, str::AbstractString) = Response(str)


const Message = Union{Request,Response}

"""
    iserror(::Response)

Does this `Response` have an error status?
"""

iserror(r::Response) = (r.status < 200 || r.status >= 300) && !isredirect(r)


"""
    isredirect(::Response)

Does this `Response` have a redirect status?
"""
isredirect(r::Response) = r.status in (301, 302, 307, 308)


"""
    method(::Response)

Method of the `Request` that yielded this `Response`.
"""

method(r::Response) = r.parent == nothing ? "" : r.parent.method


"""
    statustext(::Response) -> String

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""

statustext(r::Response) = Base.get(Parsers.STATUS_CODES, r.status, "Unknown Code")


"""
    waitforheaders(::Response)

Wait for the `Parser` (in a different task) to finish parsing the headers.
"""

function waitforheaders(r::Response)
    while r.status == 0 && r.exception == nothing
        wait(r.complete)
    end
    if r.exception != nothing
        rethrow(r.exception)
    end
end


"""
    wait(::Response)

Wait for the `Parser` (in a different task) to finish parsing the `Response`.
"""

function Base.wait(r::Response)
    while isopen(r.body) && r.exception == nothing
        wait(r.complete)
    end
    if r.exception != nothing
        rethrow(r.exception)
    end
end


"""
    header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
header(m, k::String, d::String="") = getbyfirst(m.headers, k, k => d, lceq)[2]
lceq(a,b) = lowercase(a) == lowercase(b)


"""
    setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
setheader(m, v::Pair) = setbyfirst(m.headers, Pair{String,String}(v), lceq)


"""
    defaultheader(::Message, key => value)

Set header `value` for `key` if it is not already set.
"""

function defaultheader(m, v::Pair)
    if header(m, first(v)) == ""
        setheader(m, v)
    end
    return
end



"""
    setlengthheader(::Response)

Set the Content-Length or Transfer-Encoding header according to the
`Response` `Body`.
"""

function setlengthheader(r::Request)

    l = length(r.body)
    if l == Bodies.unknownlength
        setheader(r, "Transfer-Encoding" => "chunked")
    else
        setheader(r, "Content-Length" => string(l))
    end
    return
end


"""
    appendheader(::Message, key => value)

Append a header value to `message.headers`.

If `key` is `""` the `value` is appended to the value of the previous header.

If `key` is the same as the previous header, the `vale` is [appended to the
value of the previous header with a comma
delimiter](https://stackoverflow.com/a/24502264)

`Set-Cookie` headers are not comma-combined because cookies [often contain
internal commas](https://tools.ietf.org/html/rfc6265#section-3).
"""

function appendheader(m::Message, header::Pair{String,String})
    c = m.headers
    k,v = header
    if k == ""
        c[end] = c[end][1] => string(c[end][2], v)
    elseif k != "Set-Cookie" && length(c) > 0 && k == c[end][1]
        c[end] = c[end][1] => string(c[end][2], ", ", v)
    else
        push!(m.headers, header)
    end
    return
end


"""
    httpversion(::Message)

e.g. `"HTTP/1.1"`
"""

httpversion(m::Message) = "HTTP/$(m.version.major).$(m.version.minor)"


"""
    writestartline(::IO, ::Message)

e.g. `"GET /path HTTP/1.1\\r\\n"` or `"HTTP/1.1 200 OK\\r\\n"`
"""

function writestartline(io::IO, r::Request)
    write(io, "$(r.method) $(r.uri) $(httpversion(r))\r\n")
    return
end

function writestartline(io::IO, r::Response)
    write(io, "$(httpversion(r)) $(r.status) $(statustext(r))\r\n")
    return
end


"""
    writeheaders(::IO, ::Message)

Write a line for each "name: value" pair and a trailing blank line.
"""

function writeheaders(io::IO, m::Message)
    for (name, value) in m.headers
        write(io, "$name: $value\r\n")
    end
    write(io, "\r\n")
    return
end


"""
    write(::IO, ::Message)

Write start line, headers and body of HTTP Message.
"""

function Base.write(io::IO, m::Message)
    writestartline(io, m)               # FIXME To avoid fragmentation, maybe
    writeheaders(io, m)                 # buffer header before sending to `io`
    write(io, m.body)
    return
end


"""
    readstartline!(::Message, p::Parsers.Message)

Read the start-line metadata from Parser into a `::Message` struct.
"""

function readstartline!(r::Response, m::Parsers.Message)
    r.version = VersionNumber(m.major, m.minor)
    r.status = m.status
    if isredirect(r)
        r.body = Body()
    end
    notify(r.complete)
    yield()
    return
end

function readstartline!(r::Request, m::Parsers.Message)
    r.version = VersionNumber(m.major, m.minor)
    r.method = string(m.method)
    r.uri = m.url
    return
end


"""
    connectparser(::Message, ::Parser)

Configure a `Parser` to store parsed data into this `Message`.
"""
function connectparser(m::Message, p::Parser)
    reset!(p)
    p.onbodyfragment = x->write(m.body, x)
    p.onheader = x->appendheader(m, x)
    p.onheaderscomplete = x->readstartline!(m, x)
    p.isheadresponse = (isa(m, Response) && method(m) in ("HEAD", "CONNECT"))
                       # FIXME CONNECT??
    return p
end


"""
    read!(::IO, ::Message)

Read data from `io` into a `Message` struct.
"""

function Base.read!(io::IO, m::Message)
    parser = ConnectionPool.getparser(io)
    connectparser(m, parser)
    read!(io, parser)
    close(m.body)
    return m
end


"""
    writeandread(::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
"""

function writeandread(io::IO, req::Request, res::Response)

    try                                 ;@debug 1 "write to: $io\n$req"
        write(io, req)
        closewrite(io)
        read!(io, res)
        closeread(io)                   ;@debug 2 "read from: $io\n$res"
    catch e
        @schedule close(io)
        res.exception = e
        rethrow(e)
    finally
        notify(res.complete)
    end

    return res
end


Base.take!(m::Message) = take!(m.body)


function Base.String(m::Message)
    io = IOBuffer()
    write(io, m)
    String(take!(io))
end


function Base.show(io::IO, m::Message)
    println(io, typeof(m), ":")
    println(io, "\"\"\"")
    writestartline(io, m)
    writeheaders(io, m)
    show(io, m.body)
    print(io, "\"\"\"")
    return
end


end # module Messages
