use pingora::prelude::*;
use pingora::server::Server;
use async_trait::async_trait;

struct LB {}

#[async_trait]
impl ProxyHttp for LB {
    type CTX = ();
    fn new_ctx(&self) -> () {
        ()
    }

    async fn upstream_peer(&self, _session: &mut Session, _ctx: &mut ()) -> Result<Box<HttpPeer>> {
        let peer = HttpPeer::new_uds("/tmp/app1.sock", false, "".to_string()).unwrap();
        Ok(Box::new(peer))
    }
}

fn main() {
    env_logger::init();
    let mut my_server = Server::new(None).unwrap();
    log::info!("Pingora server started");
    let mut lb = http_proxy_service(&my_server.configuration, LB {});
    lb.add_tcp("0.0.0.0:9998");

    log::info!("Pingora server starting on 0.0.0.0:9998");
    my_server.bootstrap();
    my_server.run_forever();
}