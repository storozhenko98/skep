use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command as StdCommand, Stdio};

use clap::{Parser, Subcommand};
use serde_json::Value;
use skep_protocol::{method, Request, Response, Workspace, WorkspaceIdParams};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use uuid::Uuid;

#[derive(Debug, Parser)]
#[command(name = "skepctl", version, about = "Skep daemon client and SSH bridge")]
struct Args {
    #[arg(long, global = true, default_value = "/run/skep/skepd.sock")]
    socket: PathBuf,

    #[arg(
        long,
        global = true,
        default_value = "/var/lib/skep/microsandbox/bin/msb"
    )]
    microsandbox_bin: PathBuf,

    #[arg(long, global = true, default_value = "/var/lib/skep/microsandbox")]
    microsandbox_home: PathBuf,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Bridge newline-delimited protocol messages between stdio and skepd.
    Bridge,
    /// Send one RPC request and print its JSON response.
    Call {
        method: String,
        #[arg(default_value = "{}")]
        params: String,
        #[arg(long)]
        compact: bool,
    },
    /// Attach the current terminal to a managed workspace.
    WorkspaceShell { workspace_id: String },
}

const TERMINAL_INTEGRATION_SCRIPT: &str = r#"set -eu
if command -v tmux >/dev/null 2>&1; then
  config=/etc/tmux.conf
  marker='# BEGIN SKEP TERMINAL INTEGRATION'
  if ! grep -qF "$marker" "$config" 2>/dev/null; then
    cat >>"$config" <<'EOF'

# BEGIN SKEP TERMINAL INTEGRATION
# Forward OSC 52 clipboard writes from terminal applications to the Skep client.
set -g set-clipboard on
set -as terminal-features ',xterm*:clipboard'
# END SKEP TERMINAL INTEGRATION
EOF
  fi
  tmux source-file "$config" >/dev/null 2>&1 || true
fi
"#;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    match args.command {
        Commands::Bridge => bridge(&args.socket).await?,
        Commands::Call {
            method,
            params,
            compact,
        } => {
            let params: Value = serde_json::from_str(&params)?;
            let response = call(&args.socket, &method, params).await?;
            if compact {
                println!("{}", serde_json::to_string(&response)?);
            } else {
                println!("{}", serde_json::to_string_pretty(&response)?);
            }
            if response.error.is_some() {
                std::process::exit(1);
            }
        }
        Commands::WorkspaceShell { workspace_id } => {
            let response = call(
                &args.socket,
                method::GET_WORKSPACE,
                serde_json::to_value(WorkspaceIdParams {
                    workspace_id,
                    expected_generation: None,
                })?,
            )
            .await?;
            if let Some(error) = response.error {
                eprintln!("{}: {}", error.code, error.message);
                std::process::exit(1);
            }
            let workspace: Workspace = serde_json::from_value(response.result.unwrap_or_default())?;
            prepare_terminal_integration(
                &args.microsandbox_bin,
                &args.microsandbox_home,
                &workspace.runtime_name,
            );
            let error = StdCommand::new(&args.microsandbox_bin)
                .env("MSB_HOME", &args.microsandbox_home)
                .args(["ssh", &workspace.runtime_name])
                .exec();
            return Err(error.into());
        }
    }
    Ok(())
}

fn prepare_terminal_integration(
    microsandbox_bin: &PathBuf,
    microsandbox_home: &PathBuf,
    runtime_name: &str,
) {
    let _ = StdCommand::new(microsandbox_bin)
        .env("MSB_HOME", microsandbox_home)
        .args([
            "exec",
            runtime_name,
            "--",
            "sh",
            "-lc",
            TERMINAL_INTEGRATION_SCRIPT,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

async fn bridge(socket: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let stream = UnixStream::connect(socket).await?;
    let (mut reader, mut writer) = stream.into_split();
    let inbound = tokio::spawn(async move {
        let mut stdin = tokio::io::stdin();
        tokio::io::copy(&mut stdin, &mut writer).await?;
        writer.shutdown().await
    });
    let outbound = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        tokio::io::copy(&mut reader, &mut stdout).await?;
        stdout.flush().await
    });
    let (inbound_result, outbound_result) = tokio::try_join!(inbound, outbound)?;
    inbound_result?;
    outbound_result?;
    Ok(())
}

async fn call(
    socket: &PathBuf,
    method_name: &str,
    params: Value,
) -> Result<Response, Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(socket).await?;
    let request = Request::new(Uuid::new_v4().to_string(), method_name, params);
    let mut encoded = serde_json::to_vec(&request)?;
    encoded.push(b'\n');
    stream.write_all(&encoded).await?;
    stream.flush().await?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await?;
    Ok(serde_json::from_str(&line)?)
}

#[cfg(test)]
mod tests {
    use super::TERMINAL_INTEGRATION_SCRIPT;

    #[test]
    fn terminal_integration_forwards_tmux_clipboard_sequences() {
        assert!(TERMINAL_INTEGRATION_SCRIPT.contains("set -g set-clipboard on"));
        assert!(
            TERMINAL_INTEGRATION_SCRIPT.contains("set -as terminal-features ',xterm*:clipboard'")
        );
        assert!(TERMINAL_INTEGRATION_SCRIPT.contains("tmux source-file"));
    }
}
