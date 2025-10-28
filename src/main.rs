use anyhow::Result;
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    service::RequestContext,
    tool, tool_handler, tool_router,
    transport::stdio,
};
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::path::PathBuf;
use tracing_subscriber::{self, EnvFilter};

/// Get the path to the lock file in ~/.notify-lock/
fn get_lock_file_path() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| anyhow::anyhow!("HOME environment variable not set"))?;

    let lock_dir = PathBuf::from(home).join(".notify-lock");

    // Create the directory if it doesn't exist
    if let Err(e) = std::fs::create_dir_all(&lock_dir) {
        if e.kind() != ErrorKind::AlreadyExists {
            return Err(anyhow::anyhow!("Failed to create lock directory: {}", e));
        }
    }

    Ok(lock_dir.join("say.lock"))
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct SayArgs {
    /// The text to speak using macOS say command
    pub text: String,
}

#[derive(Clone)]
pub struct NotifyServer {
    tool_router: ToolRouter<NotifyServer>,
}

#[tool_router]
impl NotifyServer {
    pub fn new() -> Self {
        Self {
            tool_router: Self::tool_router(),
        }
    }

    #[tool(description = "Say text using macOS say command")]
    async fn say(&self, Parameters(args): Parameters<SayArgs>) -> Result<CallToolResult, McpError> {
        // Spawn the say command asynchronously without blocking
        let text = args.text.clone();
        tokio::spawn(async move {
            // Get lock file path in ~/.notify-lock/
            let lock_path = match get_lock_file_path() {
                Ok(path) => path,
                Err(e) => {
                    tracing::error!("Failed to get lock file path: {}", e);
                    return;
                }
            };

            // Open or create the lock file
            let lock_file = match OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .open(&lock_path)
            {
                Ok(file) => file,
                Err(e) => {
                    tracing::error!("Failed to open lock file: {}", e);
                    return;
                }
            };

            // Acquire exclusive lock (blocks until available)
            if let Err(e) = lock_file.lock() {
                tracing::error!("Failed to acquire lock: {}", e);
                return;
            }

            tracing::debug!("Lock acquired, executing say command");

            // Execute the say command while holding the lock
            if let Err(e) = tokio::process::Command::new("say")
                .arg("-r")
                .arg("300")
                .arg(&text)
                .output()
                .await
            {
                tracing::error!("Failed to execute say command: {}", e);
            }

            // Unlock explicitly (though it will auto-unlock when file is dropped)
            if let Err(e) = lock_file.unlock() {
                tracing::error!("Failed to unlock: {}", e);
            }

            tracing::debug!("Lock released");
        });

        Ok(CallToolResult::success(vec![Content::text(format!(
            "Saying: {}",
            args.text
        ))]))
    }
}

#[tool_handler]
impl ServerHandler for NotifyServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: ProtocolVersion::V_2024_11_05,
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation::from_build_env(),
            instructions: Some(
                "This server provides a say tool that uses macOS say command to speak text."
                    .to_string(),
            ),
        }
    }

    async fn initialize(
        &self,
        _request: InitializeRequestParam,
        _context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, McpError> {
        Ok(self.get_info())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive(tracing::Level::DEBUG.into()))
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();

    tracing::info!("Starting MCP Notify server");

    let service = NotifyServer::new().serve(stdio()).await.inspect_err(|e| {
        tracing::error!("serving error: {:?}", e);
    })?;

    service.waiting().await?;
    Ok(())
}
