use std::ffi::OsStr;
#[cfg(target_os = "linux")]
use std::fs::OpenOptions;
#[cfg(target_os = "linux")]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use skep_protocol::{
    method, CreateBuilderParams, CreateWorkspaceParams, DeleteTemplateParams,
    DeleteWorkspaceParams, ExportResult, ExportTemplateParams, HostInfo, PublishTemplateParams,
    Request, ResourceProfile, Response, SetAutostartParams, Template, ToolInfo, VirtualizationInfo,
    Workspace, WorkspaceIdParams, WorkspaceKind, WorkspaceStatus, PROTOCOL_VERSION,
};
use thiserror::Error;
use tokio::fs;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::process::Command;
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub socket_path: PathBuf,
    pub state_dir: PathBuf,
    pub microsandbox_bin: PathBuf,
    pub enforce_kvm: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistentState {
    schema_version: u32,
    workspaces: Vec<Workspace>,
    templates: Vec<Template>,
}

impl Default for PersistentState {
    fn default() -> Self {
        Self {
            schema_version: 1,
            workspaces: Vec::new(),
            templates: Vec::new(),
        }
    }
}

#[derive(Clone)]
pub struct SkepService {
    config: ServerConfig,
    state: Arc<Mutex<PersistentState>>,
}

#[derive(Debug, Error)]
enum ServiceError {
    #[error("{0}")]
    InvalidArgument(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    KvmUnavailable(String),
    #[error("{0}")]
    MicrosandboxUnavailable(String),
    #[error("{0}")]
    Runtime(String),
    #[error("{0}")]
    Internal(String),
}

impl ServiceError {
    fn code(&self) -> &'static str {
        match self {
            Self::InvalidArgument(_) => "invalid_argument",
            Self::NotFound(_) => "not_found",
            Self::Conflict(_) => "conflict",
            Self::KvmUnavailable(_) => "kvm_unavailable",
            Self::MicrosandboxUnavailable(_) => "microsandbox_unavailable",
            Self::Runtime(_) => "runtime_error",
            Self::Internal(_) => "internal_error",
        }
    }
}

impl SkepService {
    pub async fn load(config: ServerConfig) -> Result<Self, Box<dyn std::error::Error>> {
        fs::create_dir_all(&config.state_dir).await?;
        fs::create_dir_all(config.state_dir.join("exports")).await?;
        let state_path = config.state_dir.join("state.json");
        let state = match fs::read(&state_path).await {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                PersistentState::default()
            }
            Err(error) => return Err(Box::new(error)),
        };
        Ok(Self {
            config,
            state: Arc::new(Mutex::new(state)),
        })
    }

    pub async fn handle(&self, request: Request) -> Response {
        let id = request.id.clone();
        if request.version != PROTOCOL_VERSION {
            return Response::error(
                id,
                "protocol_mismatch",
                format!(
                    "client protocol {} is incompatible with daemon protocol {}",
                    request.version, PROTOCOL_VERSION
                ),
            );
        }

        let result = self.dispatch(&request.method, request.params).await;
        match result {
            Ok(value) => Response::success(id, value),
            Err(error) => Response::error(id, error.code(), error.to_string()),
        }
    }

    async fn dispatch(&self, method_name: &str, params: Value) -> Result<Value, ServiceError> {
        match method_name {
            method::PING => Ok(json!({
                "ok": true,
                "daemonVersion": env!("CARGO_PKG_VERSION"),
                "protocolVersion": PROTOCOL_VERSION,
            })),
            method::HOST_INFO => serde_json::to_value(self.host_info().await)
                .map_err(|error| ServiceError::Internal(error.to_string())),
            method::LIST_WORKSPACES => {
                let state = self.state.lock().await;
                serde_json::to_value(&state.workspaces)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::GET_WORKSPACE => {
                let params: WorkspaceIdParams = decode(params)?;
                let state = self.state.lock().await;
                let workspace = state
                    .workspaces
                    .iter()
                    .find(|workspace| workspace.id == params.workspace_id)
                    .ok_or_else(|| {
                        ServiceError::NotFound(format!(
                            "workspace {} does not exist",
                            params.workspace_id
                        ))
                    })?;
                serde_json::to_value(workspace)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::LIST_TEMPLATES => {
                let state = self.state.lock().await;
                serde_json::to_value(&state.templates)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::CREATE_BUILDER => {
                let params: CreateBuilderParams = decode(params)?;
                serde_json::to_value(self.create_builder(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::BOOTSTRAP_BUILDER => {
                let params: WorkspaceIdParams = decode(params)?;
                serde_json::to_value(self.bootstrap_builder(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::PUBLISH_TEMPLATE => {
                let params: PublishTemplateParams = decode(params)?;
                serde_json::to_value(self.publish_template(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::EXPORT_TEMPLATE => {
                let params: ExportTemplateParams = decode(params)?;
                serde_json::to_value(self.export_template(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::DELETE_TEMPLATE => {
                let params: DeleteTemplateParams = decode(params)?;
                self.delete_template(params).await?;
                Ok(json!({"deleted": true}))
            }
            method::CREATE_WORKSPACE => {
                let params: CreateWorkspaceParams = decode(params)?;
                serde_json::to_value(self.create_workspace(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::START_WORKSPACE => {
                let params: WorkspaceIdParams = decode(params)?;
                serde_json::to_value(self.change_workspace_status(params, true).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::STOP_WORKSPACE => {
                let params: WorkspaceIdParams = decode(params)?;
                serde_json::to_value(self.change_workspace_status(params, false).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            method::DELETE_WORKSPACE => {
                let params: DeleteWorkspaceParams = decode(params)?;
                self.delete_workspace(params).await?;
                Ok(json!({"deleted": true}))
            }
            method::SET_AUTOSTART => {
                let params: SetAutostartParams = decode(params)?;
                serde_json::to_value(self.set_autostart(params).await?)
                    .map_err(|error| ServiceError::Internal(error.to_string()))
            }
            _ => Err(ServiceError::InvalidArgument(format!(
                "unknown method {method_name}"
            ))),
        }
    }

    async fn create_builder(&self, params: CreateBuilderParams) -> Result<Workspace, ServiceError> {
        validate_name(&params.name)?;
        self.ensure_runtime_ready().await?;
        self.validate_resources(&params.resources).await?;

        {
            let state = self.state.lock().await;
            if state
                .workspaces
                .iter()
                .any(|workspace| workspace.name == params.name)
            {
                return Err(ServiceError::Conflict(format!(
                    "a workspace named {} already exists",
                    params.name
                )));
            }
        }

        let id = Uuid::new_v4().to_string();
        let runtime_name = runtime_name("builder", &id);
        let docker_volume = format!("skep-docker-{}", short_id(&id));
        let mut args = vec![
            "create".to_string(),
            params.image.clone(),
            "--name".to_string(),
            runtime_name.clone(),
        ];
        append_launch_args(&mut args, &params.resources, &docker_volume, true);
        self.run_msb(args).await?;

        let now = now_epoch();
        let workspace = Workspace {
            id,
            generation: 1,
            name: params.name,
            runtime_name,
            kind: WorkspaceKind::Builder,
            status: WorkspaceStatus::Running,
            desired_status: WorkspaceStatus::Running,
            template_id: None,
            image: Some(params.image),
            docker_volume,
            resources: params.resources,
            autostart: false,
            created_at: now,
            updated_at: now,
            last_error: None,
            tools_installed: false,
        };
        let mut state = self.state.lock().await;
        state.workspaces.push(workspace.clone());
        self.save_locked(&state).await?;
        Ok(workspace)
    }

    async fn bootstrap_builder(
        &self,
        params: WorkspaceIdParams,
    ) -> Result<Workspace, ServiceError> {
        self.ensure_runtime_ready().await?;
        let mut workspace = self.workspace_snapshot(&params.workspace_id).await?;
        check_generation(&workspace, params.expected_generation)?;
        if workspace.kind != WorkspaceKind::Builder {
            return Err(ServiceError::InvalidArgument(
                "only builder workspaces can be bootstrapped".to_string(),
            ));
        }
        if workspace.status != WorkspaceStatus::Running {
            self.ensure_workspace_running(&workspace.runtime_name)
                .await?;
            workspace = self
                .bump_workspace(&workspace.id, |item| {
                    item.status = WorkspaceStatus::Running;
                    item.desired_status = WorkspaceStatus::Running;
                    item.last_error = None;
                })
                .await?;
        }

        const SCRIPT: &str = r#"set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl xz-utils ca-certificates git-lfs docker.io tmux
cat >/usr/local/bin/start-docker <<'EOF'
#!/bin/sh
set -eu
if ! pidof dockerd >/dev/null 2>&1; then
  mkdir -p /var/log
  dockerd >/var/log/dockerd.log 2>&1 &
fi
timeout 60 sh -c 'until docker info >/dev/null 2>&1; do sleep 0.5; done'
EOF
chmod +x /usr/local/bin/start-docker
/usr/local/bin/start-docker
"#;
        self.run_msb(vec![
            "exec".to_string(),
            workspace.runtime_name.clone(),
            "--".to_string(),
            "bash".to_string(),
            "-lc".to_string(),
            SCRIPT.to_string(),
        ])
        .await?;
        self.bump_workspace(&workspace.id, |item| {
            item.last_error = None;
            item.tools_installed = true;
        })
        .await
    }

    async fn publish_template(
        &self,
        params: PublishTemplateParams,
    ) -> Result<Template, ServiceError> {
        validate_name(&params.name)?;
        self.ensure_runtime_ready().await?;
        let workspace = self.workspace_snapshot(&params.workspace_id).await?;
        check_generation(&workspace, params.expected_generation)?;
        if workspace.kind != WorkspaceKind::Builder {
            return Err(ServiceError::InvalidArgument(
                "templates can only be published from builders".to_string(),
            ));
        }
        {
            let state = self.state.lock().await;
            if state
                .templates
                .iter()
                .any(|template| template.name == params.name)
            {
                return Err(ServiceError::Conflict(format!(
                    "a template named {} already exists",
                    params.name
                )));
            }
        }

        if workspace.status == WorkspaceStatus::Running {
            self.run_msb(vec!["stop".to_string(), workspace.runtime_name.clone()])
                .await?;
            self.bump_workspace(&workspace.id, |item| {
                item.status = WorkspaceStatus::Stopped;
                item.desired_status = WorkspaceStatus::Stopped;
            })
            .await?;
        }

        let id = Uuid::new_v4().to_string();
        let snapshot_name = runtime_name("template", &id);
        self.run_msb(vec![
            "snapshot".to_string(),
            "create".to_string(),
            snapshot_name.clone(),
            "--from".to_string(),
            workspace.runtime_name.clone(),
        ])
        .await?;
        self.run_msb(vec![
            "snapshot".to_string(),
            "verify".to_string(),
            snapshot_name.clone(),
        ])
        .await?;

        let now = now_epoch();
        let template = Template {
            id,
            generation: 1,
            name: params.name,
            snapshot_name,
            source_workspace_id: workspace.id,
            resources: workspace.resources,
            created_at: now,
            updated_at: now,
            verified: true,
        };
        let mut state = self.state.lock().await;
        state.templates.push(template.clone());
        self.save_locked(&state).await?;
        Ok(template)
    }

    async fn export_template(
        &self,
        params: ExportTemplateParams,
    ) -> Result<ExportResult, ServiceError> {
        self.ensure_runtime_ready().await?;
        let template = {
            let state = self.state.lock().await;
            state
                .templates
                .iter()
                .find(|template| template.id == params.template_id)
                .cloned()
                .ok_or_else(|| {
                    ServiceError::NotFound(format!(
                        "template {} does not exist",
                        params.template_id
                    ))
                })?
        };
        let base_name = params.output_name.unwrap_or_else(|| template.name.clone());
        validate_name(&base_name)?;
        let output = self
            .config
            .state_dir
            .join("exports")
            .join(format!("{base_name}.tar.zst"));
        self.run_msb(vec![
            "snapshot".to_string(),
            "save".to_string(),
            template.snapshot_name,
            output.to_string_lossy().into_owned(),
            "--with-image".to_string(),
        ])
        .await?;
        Ok(ExportResult {
            path: output.to_string_lossy().into_owned(),
            template_id: template.id,
        })
    }

    async fn delete_template(&self, params: DeleteTemplateParams) -> Result<(), ServiceError> {
        self.ensure_runtime_ready().await?;
        let template = {
            let state = self.state.lock().await;
            state
                .templates
                .iter()
                .find(|template| template.id == params.template_id)
                .cloned()
                .ok_or_else(|| {
                    ServiceError::NotFound(format!(
                        "template {} does not exist",
                        params.template_id
                    ))
                })?
        };
        if let Some(expected) = params.expected_generation {
            if template.generation != expected {
                return Err(ServiceError::Conflict(format!(
                    "template changed: expected generation {expected}, current generation {}",
                    template.generation
                )));
            }
        }
        self.run_msb(vec![
            "snapshot".to_string(),
            "rm".to_string(),
            "--force".to_string(),
            template.snapshot_name,
        ])
        .await?;
        let mut state = self.state.lock().await;
        state.templates.retain(|item| item.id != params.template_id);
        self.save_locked(&state).await
    }

    async fn create_workspace(
        &self,
        params: CreateWorkspaceParams,
    ) -> Result<Workspace, ServiceError> {
        validate_name(&params.name)?;
        self.ensure_runtime_ready().await?;
        let template = {
            let state = self.state.lock().await;
            if state
                .workspaces
                .iter()
                .any(|workspace| workspace.name == params.name)
            {
                return Err(ServiceError::Conflict(format!(
                    "a workspace named {} already exists",
                    params.name
                )));
            }
            state
                .templates
                .iter()
                .find(|template| template.id == params.template_id)
                .cloned()
                .ok_or_else(|| {
                    ServiceError::NotFound(format!(
                        "template {} does not exist",
                        params.template_id
                    ))
                })?
        };
        let resources = params
            .resources
            .unwrap_or_else(|| template.resources.clone());
        self.validate_resources(&resources).await?;
        let id = Uuid::new_v4().to_string();
        let runtime_name = runtime_name("workspace", &id);
        let docker_volume = format!("skep-docker-{}", short_id(&id));
        let mut args = vec![
            "run".to_string(),
            "--name".to_string(),
            runtime_name.clone(),
            "--from-snapshot".to_string(),
            template.snapshot_name,
            "--detach".to_string(),
        ];
        append_launch_args(&mut args, &resources, &docker_volume, false);
        args.extend([
            "--script".to_string(),
            "skep-boot=/usr/local/bin/start-docker >/dev/null 2>&1 || true\nexec sleep infinity"
                .to_string(),
            "--entrypoint".to_string(),
            "skep-boot".to_string(),
        ]);
        self.run_msb(args).await?;

        let now = now_epoch();
        let workspace = Workspace {
            id,
            generation: 1,
            name: params.name,
            runtime_name,
            kind: WorkspaceKind::Workspace,
            status: WorkspaceStatus::Running,
            desired_status: WorkspaceStatus::Running,
            template_id: Some(template.id),
            image: None,
            docker_volume,
            resources,
            autostart: params.autostart,
            created_at: now,
            updated_at: now,
            last_error: None,
            tools_installed: false,
        };
        let mut state = self.state.lock().await;
        state.workspaces.push(workspace.clone());
        self.save_locked(&state).await?;
        Ok(workspace)
    }

    async fn change_workspace_status(
        &self,
        params: WorkspaceIdParams,
        start: bool,
    ) -> Result<Workspace, ServiceError> {
        self.ensure_runtime_ready().await?;
        let workspace = self.workspace_snapshot(&params.workspace_id).await?;
        check_generation(&workspace, params.expected_generation)?;
        if start {
            self.ensure_workspace_running(&workspace.runtime_name)
                .await?;
        } else {
            self.run_msb(vec!["stop".to_string(), workspace.runtime_name.clone()])
                .await?;
        }
        self.bump_workspace(&workspace.id, |item| {
            let status = if start {
                WorkspaceStatus::Running
            } else {
                WorkspaceStatus::Stopped
            };
            item.status = status;
            item.desired_status = status;
            item.last_error = None;
        })
        .await
    }

    async fn delete_workspace(&self, params: DeleteWorkspaceParams) -> Result<(), ServiceError> {
        self.ensure_runtime_ready().await?;
        let workspace = self.workspace_snapshot(&params.workspace_id).await?;
        check_generation(&workspace, params.expected_generation)?;
        self.run_msb(vec![
            "rm".to_string(),
            "--force".to_string(),
            workspace.runtime_name,
        ])
        .await?;
        if params.delete_volumes {
            let result = self
                .run_msb(vec![
                    "volume".to_string(),
                    "rm".to_string(),
                    workspace.docker_volume,
                ])
                .await;
            if let Err(error) = result {
                eprintln!("skepd: workspace removed but volume cleanup failed: {error}");
            }
        }
        let mut state = self.state.lock().await;
        state
            .workspaces
            .retain(|item| item.id != params.workspace_id);
        self.save_locked(&state).await
    }

    async fn set_autostart(&self, params: SetAutostartParams) -> Result<Workspace, ServiceError> {
        let workspace = self.workspace_snapshot(&params.workspace_id).await?;
        check_generation(&workspace, params.expected_generation)?;
        self.bump_workspace(&workspace.id, |item| item.autostart = params.autostart)
            .await
    }

    async fn reconcile_autostart(&self) {
        let workspaces: Vec<Workspace> = {
            let state = self.state.lock().await;
            state
                .workspaces
                .iter()
                .filter(|workspace| {
                    workspace.kind == WorkspaceKind::Workspace && workspace.autostart
                })
                .cloned()
                .collect()
        };

        for workspace in workspaces {
            let result = async {
                self.ensure_runtime_ready().await?;
                self.ensure_workspace_running(&workspace.runtime_name).await
            }
            .await;
            let update = match result {
                Ok(_) => {
                    self.bump_workspace(&workspace.id, |item| {
                        item.status = WorkspaceStatus::Running;
                        item.desired_status = WorkspaceStatus::Running;
                        item.last_error = None;
                    })
                    .await
                }
                Err(error) => {
                    let message = error.to_string();
                    self.bump_workspace(&workspace.id, |item| {
                        item.status = WorkspaceStatus::Error;
                        item.desired_status = WorkspaceStatus::Running;
                        item.last_error = Some(message);
                    })
                    .await
                }
            };
            if let Err(error) = update {
                eprintln!(
                    "skepd: failed to persist autostart result for {}: {error}",
                    workspace.runtime_name
                );
            }
        }
    }

    async fn workspace_snapshot(&self, id: &str) -> Result<Workspace, ServiceError> {
        let state = self.state.lock().await;
        state
            .workspaces
            .iter()
            .find(|workspace| workspace.id == id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("workspace {id} does not exist")))
    }

    async fn bump_workspace<F>(&self, id: &str, update: F) -> Result<Workspace, ServiceError>
    where
        F: FnOnce(&mut Workspace),
    {
        let mut state = self.state.lock().await;
        let workspace = state
            .workspaces
            .iter_mut()
            .find(|workspace| workspace.id == id)
            .ok_or_else(|| ServiceError::NotFound(format!("workspace {id} does not exist")))?;
        update(workspace);
        workspace.generation += 1;
        workspace.updated_at = now_epoch();
        let result = workspace.clone();
        self.save_locked(&state).await?;
        Ok(result)
    }

    async fn save_locked(&self, state: &PersistentState) -> Result<(), ServiceError> {
        let bytes = serde_json::to_vec_pretty(state)
            .map_err(|error| ServiceError::Internal(error.to_string()))?;
        let state_path = self.config.state_dir.join("state.json");
        let temporary_path = self.config.state_dir.join("state.json.tmp");
        fs::write(&temporary_path, bytes)
            .await
            .map_err(|error| ServiceError::Internal(error.to_string()))?;
        fs::rename(&temporary_path, &state_path)
            .await
            .map_err(|error| ServiceError::Internal(error.to_string()))?;
        Ok(())
    }

    async fn ensure_runtime_ready(&self) -> Result<(), ServiceError> {
        if self.config.enforce_kvm {
            let virtualization = virtualization_info().await;
            if !virtualization.kvm_usable {
                return Err(ServiceError::KvmUnavailable(
                    virtualization.reason.unwrap_or_else(|| {
                        "KVM is not usable by the skepd service account".to_string()
                    }),
                ));
            }
        }
        let tool = tool_info(&self.config.microsandbox_bin).await;
        if !tool.installed {
            return Err(ServiceError::MicrosandboxUnavailable(format!(
                "Microsandbox was not found at {}",
                self.config.microsandbox_bin.display()
            )));
        }
        Ok(())
    }

    async fn ensure_workspace_running(&self, runtime_name: &str) -> Result<(), ServiceError> {
        let output = self
            .run_msb(vec![
                "status".to_string(),
                runtime_name.to_string(),
                "--format".to_string(),
                "json".to_string(),
            ])
            .await?;
        let value: Value = serde_json::from_str(&output).map_err(|error| {
            ServiceError::Runtime(format!(
                "Microsandbox returned invalid status for {runtime_name}: {error}"
            ))
        })?;
        let status = value.get("status").and_then(Value::as_str).ok_or_else(|| {
            ServiceError::Runtime(format!(
                "Microsandbox status for {runtime_name} did not contain a status"
            ))
        })?;
        if matches!(status, "Running" | "Draining") {
            return Ok(());
        }
        self.run_msb(vec!["start".to_string(), runtime_name.to_string()])
            .await?;
        Ok(())
    }

    async fn validate_resources(&self, resources: &ResourceProfile) -> Result<(), ServiceError> {
        if resources.starting_cpus == 0
            || resources.maximum_cpus < resources.starting_cpus
            || resources.starting_memory_mib < 512
            || resources.maximum_memory_mib < resources.starting_memory_mib
            || resources.tmpfs_mib < 64
            || resources.docker_volume_mib < 1024
        {
            return Err(ServiceError::InvalidArgument(
                "invalid resource profile: maximums must cover starting values and memory/volume minimums must be respected"
                    .to_string(),
            ));
        }
        let host = self.host_info().await;
        if resources.maximum_cpus as u32 > host.cpu_count {
            return Err(ServiceError::InvalidArgument(format!(
                "maximum CPUs {} exceeds host capacity {}",
                resources.maximum_cpus, host.cpu_count
            )));
        }
        if host.total_memory_mib > 0 && resources.maximum_memory_mib as u64 >= host.total_memory_mib
        {
            return Err(ServiceError::InvalidArgument(format!(
                "maximum memory {} MiB must leave memory for the host ({} MiB total)",
                resources.maximum_memory_mib, host.total_memory_mib
            )));
        }
        Ok(())
    }

    async fn run_msb<I, S>(&self, args: I) -> Result<String, ServiceError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let output = Command::new(&self.config.microsandbox_bin)
            .args(args)
            .output()
            .await
            .map_err(|error| {
                ServiceError::MicrosandboxUnavailable(format!(
                    "failed to start {}: {error}",
                    self.config.microsandbox_bin.display()
                ))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            return Err(ServiceError::Runtime(if stderr.is_empty() {
                stdout
            } else {
                stderr
            }));
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    async fn host_info(&self) -> HostInfo {
        let os_release = read_os_release().await;
        let hostname = match read_trimmed("/etc/hostname").await {
            Some(value) if !value.is_empty() => value,
            _ => command_line("hostname", std::iter::empty::<&str>())
                .await
                .unwrap_or_default(),
        };
        let kernel = command_line("uname", ["-sr"]).await.unwrap_or_default();
        let architecture = command_line("uname", ["-m"]).await.unwrap_or_default();
        let cpu_count = std::thread::available_parallelism()
            .map(|count| count.get() as u32)
            .unwrap_or(1);
        let (total_memory_mib, available_memory_mib) = memory_info().await;
        let (root_disk_total_mib, root_disk_available_mib) = disk_info().await;
        let microsandbox = tool_info(&self.config.microsandbox_bin).await;
        HostInfo {
            daemon_version: env!("CARGO_PKG_VERSION").to_string(),
            protocol_version: PROTOCOL_VERSION,
            hostname,
            operating_system: os_release.0,
            operating_system_version: os_release.1,
            kernel,
            architecture,
            cpu_count,
            total_memory_mib,
            available_memory_mib,
            root_disk_total_mib,
            root_disk_available_mib,
            systemd: cfg!(target_os = "linux") && Path::new("/run/systemd/system").exists(),
            ipv4: network_capability(4).await,
            ipv6: network_capability(6).await,
            virtualization: virtualization_info().await,
            microsandbox,
            suggested_profile: suggested_profile(cpu_count, total_memory_mib),
        }
    }
}

pub async fn run_server(config: ServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = config.socket_path.parent() {
        fs::create_dir_all(parent).await?;
    }
    match fs::remove_file(&config.socket_path).await {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(Box::new(error)),
    }
    let listener = UnixListener::bind(&config.socket_path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&config.socket_path, std::fs::Permissions::from_mode(0o660)).await?;
    }
    let service = SkepService::load(config).await?;
    let autostart_service = service.clone();
    tokio::spawn(async move {
        autostart_service.reconcile_autostart().await;
    });

    loop {
        tokio::select! {
            result = listener.accept() => {
                let (stream, _) = result?;
                let service = service.clone();
                tokio::spawn(async move {
                    if let Err(error) = handle_connection(service, stream).await {
                        eprintln!("skepd: connection failed: {error}");
                    }
                });
            }
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    Ok(())
}

async fn handle_connection(
    service: SkepService,
    stream: UnixStream,
) -> Result<(), Box<dyn std::error::Error>> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) => service.handle(request).await,
            Err(error) => Response::error("", "invalid_json", error.to_string()),
        };
        let mut encoded = serde_json::to_vec(&response)?;
        encoded.push(b'\n');
        writer.write_all(&encoded).await?;
        writer.flush().await?;
    }
    Ok(())
}

fn decode<T: DeserializeOwned>(value: Value) -> Result<T, ServiceError> {
    serde_json::from_value(value).map_err(|error| ServiceError::InvalidArgument(error.to_string()))
}

fn validate_name(name: &str) -> Result<(), ServiceError> {
    if name.is_empty() || name.len() > 64 {
        return Err(ServiceError::InvalidArgument(
            "name must contain between 1 and 64 characters".to_string(),
        ));
    }
    if !name
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | ' '))
    {
        return Err(ServiceError::InvalidArgument(
            "name may contain only letters, numbers, spaces, dashes, and underscores".to_string(),
        ));
    }
    Ok(())
}

fn check_generation(workspace: &Workspace, expected: Option<u64>) -> Result<(), ServiceError> {
    if let Some(expected) = expected {
        if workspace.generation != expected {
            return Err(ServiceError::Conflict(format!(
                "workspace changed: expected generation {expected}, current generation {}",
                workspace.generation
            )));
        }
    }
    Ok(())
}

fn append_launch_args(
    args: &mut Vec<String>,
    resources: &ResourceProfile,
    volume: &str,
    include_root_disk: bool,
) {
    args.extend([
        "--cpus".to_string(),
        resources.starting_cpus.to_string(),
        "--max-cpus".to_string(),
        resources.maximum_cpus.to_string(),
        "--memory".to_string(),
        format!("{}M", resources.starting_memory_mib),
        "--max-memory".to_string(),
        format!("{}M", resources.maximum_memory_mib),
        "--tmpfs".to_string(),
        format!("/tmp:{}M", resources.tmpfs_mib),
        "--mount-named".to_string(),
        format!(
            "{volume}:/var/lib/docker:kind=disk,size={}M",
            resources.docker_volume_mib
        ),
        "--net".to_string(),
        resources.network_profile.clone(),
        "--shell".to_string(),
        "/bin/bash".to_string(),
        "--workdir".to_string(),
        "/root".to_string(),
        "--label".to_string(),
        "managed-by=skep".to_string(),
    ]);
    if include_root_disk {
        args.extend([
            "--root-disk".to_string(),
            format!("{}M", resources.root_disk_mib),
        ]);
    }
    for server in &resources.dns_servers {
        args.push("--dns-nameserver".to_string());
        args.push(server.clone());
    }
}

fn runtime_name(kind: &str, id: &str) -> String {
    format!("skep-{kind}-{}", short_id(id))
}

fn short_id(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

async fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .await
        .ok()
        .map(|value| value.trim().to_string())
}

#[cfg(target_os = "linux")]
async fn read_os_release() -> (String, String) {
    let contents = fs::read_to_string("/etc/os-release")
        .await
        .unwrap_or_default();
    let mut name = String::new();
    let mut version = String::new();
    for line in contents.lines() {
        if let Some(value) = line.strip_prefix("ID=") {
            name = value.trim_matches('"').to_string();
        }
        if let Some(value) = line.strip_prefix("VERSION_ID=") {
            version = value.trim_matches('"').to_string();
        }
    }
    (name, version)
}

#[cfg(target_os = "macos")]
async fn read_os_release() -> (String, String) {
    let version = command_line("sw_vers", ["-productVersion"])
        .await
        .unwrap_or_default();
    ("macOS".to_string(), version)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
async fn read_os_release() -> (String, String) {
    (std::env::consts::OS.to_string(), String::new())
}

#[cfg(target_os = "linux")]
async fn memory_info() -> (u64, u64) {
    let contents = fs::read_to_string("/proc/meminfo")
        .await
        .unwrap_or_default();
    let mut total = 0;
    let mut available = 0;
    for line in contents.lines() {
        if let Some(value) = line.strip_prefix("MemTotal:") {
            total = parse_kib(value) / 1024;
        }
        if let Some(value) = line.strip_prefix("MemAvailable:") {
            available = parse_kib(value) / 1024;
        }
    }
    (total, available)
}

#[cfg(target_os = "macos")]
async fn memory_info() -> (u64, u64) {
    let total_bytes = command_line("sysctl", ["-n", "hw.memsize"])
        .await
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0);
    let vm_stat = command_line("vm_stat", std::iter::empty::<&str>())
        .await
        .unwrap_or_default();
    let page_size = vm_stat
        .lines()
        .next()
        .and_then(|line| line.split("page size of ").nth(1))
        .and_then(|value| value.split_whitespace().next())
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(16_384);
    let available_pages: u64 = vm_stat
        .lines()
        .filter(|line| {
            line.starts_with("Pages free:")
                || line.starts_with("Pages inactive:")
                || line.starts_with("Pages speculative:")
                || line.starts_with("Pages purgeable:")
        })
        .filter_map(|line| line.split(':').nth(1))
        .filter_map(|value| value.trim().trim_end_matches('.').parse::<u64>().ok())
        .sum();
    (
        total_bytes / 1_048_576,
        available_pages.saturating_mul(page_size) / 1_048_576,
    )
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
async fn memory_info() -> (u64, u64) {
    (0, 0)
}

#[cfg(target_os = "linux")]
fn parse_kib(value: &str) -> u64 {
    value
        .split_whitespace()
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
}

async fn disk_info() -> (u64, u64) {
    let output = Command::new("df").args(["-Pk", "/"]).output().await;
    let Ok(output) = output else { return (0, 0) };
    let text = String::from_utf8_lossy(&output.stdout);
    let Some(line) = text.lines().nth(1) else {
        return (0, 0);
    };
    let columns: Vec<&str> = line.split_whitespace().collect();
    if columns.len() < 4 {
        return (0, 0);
    }
    let total_kib = columns[1].parse::<u64>().unwrap_or(0);
    let available_kib = columns[3].parse::<u64>().unwrap_or(0);
    (total_kib / 1024, available_kib / 1024)
}

async fn virtualization_info() -> VirtualizationInfo {
    #[cfg(target_os = "macos")]
    {
        return VirtualizationInfo {
            provider: Some("apple-virtualization".to_string()),
            cpu_virtualization: true,
            kvm_device: false,
            kvm_usable: cfg!(target_arch = "aarch64"),
            kvm_api_version: None,
            reason: if cfg!(target_arch = "aarch64") {
                None
            } else {
                Some("Microsandbox local workspaces require Apple Silicon".to_string())
            },
        };
    }

    #[cfg(not(target_os = "macos"))]
    {
        let provider = command_line("systemd-detect-virt", std::iter::empty::<&str>())
            .await
            .filter(|value| !value.is_empty() && value != "none");
        let cpuinfo = fs::read_to_string("/proc/cpuinfo")
            .await
            .unwrap_or_default();
        let cpu_virtualization = cpuinfo
            .split_whitespace()
            .any(|token| token == "vmx" || token == "svm");
        let kvm_device = Path::new("/dev/kvm").exists();
        let mut kvm_api_version = None;
        let mut open_error = None;
        if kvm_device {
            match OpenOptions::new().read(true).write(true).open("/dev/kvm") {
                Ok(file) => {
                    let result = unsafe { libc::ioctl(file.as_raw_fd(), 0xAE00) };
                    if result >= 0 {
                        kvm_api_version = Some(result);
                    } else {
                        open_error = Some(std::io::Error::last_os_error().to_string());
                    }
                }
                Err(error) => open_error = Some(error.to_string()),
            }
        }
        let kvm_usable = cpu_virtualization && kvm_api_version.is_some();
        let reason = if kvm_usable {
            None
        } else if !cpu_virtualization {
            Some(
            "the host CPU does not expose VMX/SVM virtualization flags; enable nested virtualization or choose a compatible host"
                .to_string(),
        )
        } else if !kvm_device {
            Some("/dev/kvm is missing; load KVM or enable nested virtualization".to_string())
        } else {
            Some(format!(
                "/dev/kvm could not be opened and queried: {}",
                open_error.unwrap_or_else(|| "unknown error".to_string())
            ))
        };
        VirtualizationInfo {
            provider,
            cpu_virtualization,
            kvm_device,
            kvm_usable,
            kvm_api_version,
            reason,
        }
    }
}

async fn network_capability(version: u8) -> bool {
    #[cfg(target_os = "linux")]
    {
        return if version == 4 {
            Path::new("/proc/net/route").exists()
        } else {
            fs::metadata("/proc/net/if_inet6")
                .await
                .map(|metadata| metadata.len() > 0)
                .unwrap_or(false)
        };
    }
    #[cfg(target_os = "macos")]
    {
        let flag = if version == 4 { "inet " } else { "inet6 " };
        return command_line("ifconfig", ["-a"])
            .await
            .map(|output| output.contains(flag))
            .unwrap_or(false);
    }
    #[allow(unreachable_code)]
    false
}

async fn tool_info(path: &Path) -> ToolInfo {
    match Command::new(path).arg("--version").output().await {
        Ok(output) if output.status.success() => ToolInfo {
            installed: true,
            version: Some(String::from_utf8_lossy(&output.stdout).trim().to_string()),
            path: Some(path.to_string_lossy().into_owned()),
        },
        _ => ToolInfo {
            installed: false,
            version: None,
            path: None,
        },
    }
}

async fn command_line<I, S>(program: &str, args: I) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program).args(args).output().await.ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn suggested_profile(cpu_count: u32, total_memory_mib: u64) -> ResourceProfile {
    let maximum_cpus = cpu_count.clamp(1, u8::MAX as u32) as u8;
    let starting_cpus = maximum_cpus.saturating_sub(1).clamp(1, 4);
    let host_reserve = 1024u64.min(total_memory_mib.saturating_div(4).max(256));
    let maximum_memory = total_memory_mib.saturating_sub(host_reserve).max(512) as u32;
    let starting_memory = maximum_memory.clamp(512, 4096);
    ResourceProfile {
        starting_cpus,
        maximum_cpus,
        starting_memory_mib: starting_memory,
        maximum_memory_mib: maximum_memory,
        ..ResourceProfile::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    async fn test_service() -> (tempfile::TempDir, SkepService) {
        let temp = tempfile::tempdir().unwrap();
        let fake_msb = temp.path().join("msb");
        let log_path = temp.path().join("msb.log");
        std::fs::write(
            &fake_msb,
            format!(
                "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'msb 0.6.8-test'; exit 0; fi\nprintf '%s\\n' \"$*\" >> '{}'\nif [ \"$1\" = \"status\" ]; then echo '{{\"status\":\"Stopped\"}}'; fi\n",
                log_path.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&fake_msb, std::fs::Permissions::from_mode(0o755)).unwrap();
        let service = SkepService::load(ServerConfig {
            socket_path: temp.path().join("skepd.sock"),
            state_dir: temp.path().join("state"),
            microsandbox_bin: fake_msb,
            enforce_kvm: false,
        })
        .await
        .unwrap();
        (temp, service)
    }

    #[tokio::test]
    async fn ping_and_unknown_method() {
        let (_temp, service) = test_service().await;
        let ping = service
            .handle(Request::new("1", method::PING, json!({})))
            .await;
        assert!(ping.error.is_none());
        let unknown = service
            .handle(Request::new("2", "does.not.exist", json!({})))
            .await;
        assert_eq!(unknown.error.unwrap().code, "invalid_argument");
    }

    #[tokio::test]
    async fn lifecycle_persists_and_uses_exact_runtime_names() {
        let (temp, service) = test_service().await;
        let host = service.host_info().await;
        let profile = ResourceProfile {
            starting_cpus: 1,
            maximum_cpus: 1,
            starting_memory_mib: 512,
            maximum_memory_mib: 512,
            ..host.suggested_profile
        };
        let builder = service
            .create_builder(CreateBuilderParams {
                name: "base".to_string(),
                image: "ubuntu:24.04".to_string(),
                resources: profile,
            })
            .await
            .unwrap();
        assert_eq!(builder.kind, WorkspaceKind::Builder);
        let prepared_builder = service
            .bootstrap_builder(WorkspaceIdParams {
                workspace_id: builder.id.clone(),
                expected_generation: Some(builder.generation),
            })
            .await
            .unwrap();
        assert!(prepared_builder.tools_installed);
        let template = service
            .publish_template(PublishTemplateParams {
                workspace_id: builder.id.clone(),
                name: "dev".to_string(),
                expected_generation: None,
            })
            .await
            .unwrap();
        assert!(template.verified);
        let workspace = service
            .create_workspace(CreateWorkspaceParams {
                template_id: template.id.clone(),
                name: "feature".to_string(),
                resources: None,
                autostart: true,
            })
            .await
            .unwrap();
        service.reconcile_autostart().await;
        let reconciled = service.workspace_snapshot(&workspace.id).await.unwrap();
        let stopped = service
            .change_workspace_status(
                WorkspaceIdParams {
                    workspace_id: workspace.id.clone(),
                    expected_generation: Some(reconciled.generation),
                },
                false,
            )
            .await
            .unwrap();
        assert_eq!(stopped.status, WorkspaceStatus::Stopped);
        service
            .delete_workspace(DeleteWorkspaceParams {
                workspace_id: stopped.id,
                expected_generation: Some(stopped.generation),
                delete_volumes: true,
            })
            .await
            .unwrap();
        service
            .delete_template(DeleteTemplateParams {
                template_id: template.id,
                expected_generation: Some(template.generation),
            })
            .await
            .unwrap();
        let state: PersistentState = serde_json::from_slice(
            &fs::read(temp.path().join("state/state.json"))
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(state.workspaces.len(), 1);
        assert!(state.templates.is_empty());
        let log = fs::read_to_string(temp.path().join("msb.log"))
            .await
            .unwrap();
        assert!(log.contains(&builder.runtime_name));
        assert!(log.contains("snapshot verify"));
        assert!(log.contains("snapshot rm --force"));
        assert!(log.contains("exec sleep infinity"));
        assert!(log.contains(&format!("start {}", workspace.runtime_name)));
        assert!(log.contains("volume rm"));
        let create_line = log
            .lines()
            .find(|line| line.starts_with("create ubuntu:24.04"))
            .unwrap();
        assert!(create_line.contains("--root-disk"));
        let workspace_line = log
            .lines()
            .find(|line| line.starts_with("run --name skep-workspace-"))
            .unwrap();
        assert!(workspace_line.contains("--from-snapshot"));
        assert!(!workspace_line.contains("--root-disk"));
    }

    #[test]
    fn suggested_resources_leave_host_headroom() {
        let profile = suggested_profile(2, 3900);
        assert_eq!(profile.starting_cpus, 1);
        assert_eq!(profile.maximum_cpus, 2);
        assert!(profile.maximum_memory_mib < 3900);
        assert!(profile.starting_memory_mib <= profile.maximum_memory_mib);
    }
}
