use anyhow::Result;
use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::*,
    service::RequestContext,
    tool, tool_handler, tool_router,
    transport::stdio,
};
use tracing_subscriber::{self, EnvFilter};

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
            if let Err(e) = tokio::process::Command::new("say")
                .arg(&text)
                .output()
                .await
            {
                tracing::error!("Failed to execute say command: {}", e);
            }
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
