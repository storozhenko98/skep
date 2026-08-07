use std::path::PathBuf;

use clap::Parser;
use skepd::{run_server, ServerConfig};

#[derive(Debug, Parser)]
#[command(name = "skepd", version, about = "Skep remote workspace daemon")]
struct Args {
    #[arg(long, default_value = "/run/skep/skepd.sock")]
    socket: PathBuf,

    #[arg(long, default_value = "/var/lib/skep")]
    state_dir: PathBuf,

    #[arg(long, default_value = "msb")]
    microsandbox_bin: PathBuf,

    /// Trust Microsandbox's native host virtualization instead of requiring Linux KVM.
    #[arg(long)]
    allow_native_virtualization: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    run_server(ServerConfig {
        socket_path: args.socket,
        state_dir: args.state_dir,
        microsandbox_bin: args.microsandbox_bin,
        enforce_kvm: !args.allow_native_virtualization,
    })
    .await?;
    Ok(())
}
