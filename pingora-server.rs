use pingora::{prelude::*, server::configuration::ServerConf};
use pingora::server::Server;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};
use http::Method;

struct LB {
    write_peers: [&'static str; 2],
    read_peer: &'static str,
    index: AtomicUsize,
}

#[async_trait]
impl ProxyHttp for LB {
    type CTX = ();
    fn new_ctx(&self) -> () {
        ()
    }

    async fn upstream_peer(&self, _session: &mut Session, _ctx: &mut ()) -> Result<Box<HttpPeer>> {
        _session.set_keepalive(Some(60 * 1000));
        match _session.req_header().method {
            Method::POST => {
            let peer = HttpPeer::new_uds(self.write_peers[self.index.fetch_add(1, Ordering::Relaxed) % self.write_peers.len()], false, "".to_string()).unwrap();
            Ok(Box::new(peer))
            },
            _ => {
                let peer = HttpPeer::new_uds(self.read_peer, false, "".to_string()).unwrap();
                Ok(Box::new(peer))
            }
        }
    }

}

fn main() {
    env_logger::init();
    let mut conf = ServerConf::new().unwrap();
    conf.upstream_connect_offload_thread_per_pool = Some(16);
    conf.upstream_connect_offload_thread_per_pool = Some(16);
    let mut server = Server::new_with_opt_and_conf(Opt::parse_args(), conf);
    let write_peers = ["/dev/shm/app1.sock", "/dev/shm/app2.sock"];
    let read_peer = "/dev/shm/1.sock";
    let mut lb = http_proxy_service(&server.configuration, LB { write_peers, read_peer, index: AtomicUsize::new(0) });
    lb.add_tcp("0.0.0.0:9998");
    server.add_service(lb);
    server.bootstrap();
    server.run_forever();
}