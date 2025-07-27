use pingora::{prelude::*, server::configuration::{Opt, ServerConf}, upstreams::peer::{Peer}, protocols::TcpKeepalive};
use pingora::server::Server;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

struct LB {
    write_peer1: HttpPeer,
    write_peer2: HttpPeer,
    index: AtomicUsize,
}

#[async_trait]
impl ProxyHttp for LB {
    type CTX = ();
    fn new_ctx(&self) -> () {
        ()
    }

    async fn upstream_peer(&self, _session: &mut Session, _ctx: &mut ()) -> Result<Box<HttpPeer>> {
        let peer = match self.index.fetch_add(1, Ordering::Relaxed) % 2 {
            0 => &self.write_peer1,
            1 => &self.write_peer2,
            _ => &self.write_peer1,
        };
        Ok(Box::new(peer.clone()))
    }
}

fn create_peer(host: &str, port: u16) -> HttpPeer {
    let mut peer = HttpPeer::new(format!("{}:{}", host, port), false, "".to_string());
    let options = peer.get_mut_peer_options().unwrap();
    options.tcp_fast_open = true;
    options.tcp_keepalive = Some(TcpKeepalive {
        idle: Duration::from_secs(1),
        interval: Duration::from_secs(10),
        count: 3,
        #[cfg(target_os = "linux")]
        user_timeout: Duration::from_secs(1),
    });
    options.tcp_recv_buf = Some(256 * 1024);
    options.idle_timeout = Some(Duration::from_secs(1));
    peer
}

fn main() {
    env_logger::init();
    let mut conf = ServerConf::new().unwrap();
    conf.threads = 1;
    let mut server = Server::new_with_opt_and_conf(Opt::parse_args(), conf);
    
    let lb = LB {
        write_peer1: create_peer("app1", 9999),
        write_peer2: create_peer("app2", 9999),
        index: AtomicUsize::new(0),
    };
    
    let mut lb_service = http_proxy_service(&server.configuration, lb);
    let port = std::env::var("PORT").expect("Missing PORT env var");
    lb_service.add_tcp(format!("0.0.0.0:{}", port).as_str());
    server.add_service(lb_service);
    server.bootstrap();
    server.run_forever();
}