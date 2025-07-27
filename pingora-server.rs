use pingora::{prelude::*, server::configuration::{Opt, ServerConf}, upstreams::peer::Peer};
use pingora::server::Server;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};
use http::Method;
use trust_dns_resolver::config::ResolverConfig;
use trust_dns_resolver::config::ResolverOpts;
use trust_dns_resolver::Resolver;

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
    let peer = HttpPeer::new(format!("{}:{}", host, port), false, "".to_string());
    HttpPeer::tcp_fast_open(&peer);
    HttpPeer::tcp_keepalive(&peer);
    HttpPeer::tcp_recv_buf(&peer);
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