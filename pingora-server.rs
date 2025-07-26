use pingora::prelude::*;
use pingora::lb::{LoadBalancer};
use pingora_load_balancing::{Backends};
use pingora::server::Server;
use async_trait::async_trait;
use pingora::lb::discovery::Static;
use std::os::unix::net::UnixStream;
use std::net::ToSocketAddrs;
use std::io;

struct LB {
    lb: LoadBalancer<RoundRobin>,
}

struct UnixPeer(UnixStream);

impl UnixPeer {
    fn new(path: &str) -> Self {
        Self(UnixStream::connect(path).unwrap())
    }
}

impl ToSocketAddrs for UnixPeer {
    type Iter = std::iter::Once<std::net::SocketAddr>;
    fn to_socket_addrs(&self) -> io::Result<Self::Iter> {
        let addr: std::net::SocketAddr = self.0.local_addr().unwrap().clone();
        Ok(std::iter::once(addr))
    }
}

#[async_trait]
impl ProxyHttp for LB {
    type CTX = ();
    fn new_ctx(&self) -> () {
        ()
    }

    async fn upstream_peer(&self, _session: &mut Session, _ctx: &mut ()) -> Result<Box<HttpPeer>> {
        let backend = self.lb.select(b"", 256).unwrap();
        log::info!("Upstream peer: {}", backend.to_string());
        let peer = HttpPeer::new_uds(backend.to_string().as_str(), false, "".to_string()).unwrap();
        Ok(Box::new(peer))
    }
}

fn main() {
    env_logger::init();
    let mut my_server = Server::new(None).unwrap();
    log::info!("Pingora server started");
    let backends = Backends::new(Static::try_from_iter(vec![
        UnixPeer::new("/dev/shm/app1.sock"),
        UnixPeer::new("/dev/shm/app2.sock"),
    ]).unwrap());
    let upstreams: LoadBalancer<RoundRobin> = LoadBalancer::from_backends(backends);
    log::debug!("Finished setting up upstreams");

    let mut lb = http_proxy_service(&my_server.configuration, LB { lb: upstreams });
    lb.add_tcp("0.0.0.0:9998");

    log::info!("Pingora server starting on 0.0.0.0:9998");
    my_server.bootstrap();
    my_server.run_forever();
}