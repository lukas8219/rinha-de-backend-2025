use pingora::{prelude::*, server::configuration::{Opt, ServerConf}, upstreams::peer::{Peer}, protocols::TcpKeepalive};
use pingora::server::Server;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};
use http::Method;
use std::time::Duration;

struct LB {
    write_peer1: HttpPeer,
    write_peer2: HttpPeer,
    read_peer: HttpPeer,
    index: AtomicUsize,
}

#[async_trait]
impl ProxyHttp for LB {
    type CTX = ();
    fn new_ctx(&self) -> () {
        ()
    }

    async fn upstream_peer(&self, _session: &mut Session, _ctx: &mut ()) -> Result<Box<HttpPeer>> {
        let peer = match _session.req_header().method {
            Method::POST => {
                let idx = self.index.fetch_add(1, Ordering::Relaxed);
                if idx % 2 == 0 {
                    &self.write_peer1
                } else {
                    &self.write_peer2
                }
            },
            _ => &self.read_peer
        };
        
        Ok(Box::new(peer.clone()))
    }
}

fn create_peer(host: &str, port: u16) -> HttpPeer {
    // let resolver = Resolver::new(ResolverConfig::default(), ResolverOpts::default()).unwrap();
    // let resolved_hostname = resolver.lookup_ip(host).unwrap().iter().next().unwrap().to_string();
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
    let conf = ServerConf::new().unwrap();
    let mut server = Server::new_with_opt_and_conf(Opt::parse_args(), conf);
    
    let lb = LB {
        write_peer1: create_peer("app1", 3000),
        write_peer2: create_peer("app2", 3000),
        read_peer: create_peer("consumer", 9999),
        index: AtomicUsize::new(0),
    };
    
    let mut lb_service = http_proxy_service(&server.configuration, lb);
    let port = std::env::var("PORT").expect("Missing PORT env var");
    lb_service.add_tcp(format!("0.0.0.0:{}", port).as_str());
    server.add_service(lb_service);
    server.bootstrap();
    server.run_forever();
}