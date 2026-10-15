"""Loopback-only opaque TLS CONNECT relay with a file-controlled outage.
Never records request headers, credentials, paths, or decrypted TLS contents.
"""
import asyncio, pathlib, sys, time
control=pathlib.Path(sys.argv[1]); port=int(sys.argv[2]); peers=set(); offline=False

def log(event): print(f'{time.time():.3f} {event}',flush=True)
async def handle(reader,writer):
    peers.add(writer)
    try:
        raw=await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'),10)
        first=raw.split(b'\r\n',1)[0].decode('ascii')
        method,target,_=first.split(' ')
        host,number=target.rsplit(':',1)
        if method!='CONNECT' or int(number)!=443 or not (host.endswith('.aliyuncs.com') or host.endswith('.aliyuncs.com.cn')):
            writer.write(b'HTTP/1.1 403 Forbidden\r\n\r\n');await writer.drain();return
        if offline:
            log('blocked');writer.write(b'HTTP/1.1 503 Service Unavailable\r\n\r\n');await writer.drain();return
        upstream,remote=await asyncio.open_connection(host,443);peers.add(remote)
        writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n');await writer.drain();log('tunnel-open')
        async def relay(source,dest):
            try:
                while chunk:=await source.read(65536):
                    dest.write(chunk);await dest.drain()
            finally: dest.close()
        try: await asyncio.gather(relay(reader,remote),relay(upstream,writer))
        finally: peers.discard(remote);remote.close();log('tunnel-close')
    except Exception as e: log('connection-ended '+type(e).__name__)
    finally: peers.discard(writer);writer.close()
async def monitor():
    global offline
    while True:
        value=control.exists() and control.read_text().strip()=='offline'
        if value!=offline:
            offline=value;log('OFFLINE' if value else 'ONLINE')
            if value:
                for peer in list(peers):peer.close()
        await asyncio.sleep(.1)
async def main():
    server=await asyncio.start_server(handle,'127.0.0.1',port);log('ready')
    async with server:await asyncio.gather(server.serve_forever(),monitor())
asyncio.run(main())
