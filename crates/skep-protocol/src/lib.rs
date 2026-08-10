use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

pub mod method {
    pub const PING: &str = "ping";
    pub const HOST_INFO: &str = "host.info";
    pub const PURGE_HOST: &str = "host.purge";
    pub const LIST_WORKSPACES: &str = "workspace.list";
    pub const GET_WORKSPACE: &str = "workspace.get";
    pub const CREATE_BUILDER: &str = "builder.create";
    pub const BOOTSTRAP_BUILDER: &str = "builder.bootstrap";
    pub const PUBLISH_TEMPLATE: &str = "template.publish";
    pub const LIST_TEMPLATES: &str = "template.list";
    pub const EXPORT_TEMPLATE: &str = "template.export";
    pub const DELETE_TEMPLATE: &str = "template.delete";
    pub const CREATE_WORKSPACE: &str = "workspace.create";
    pub const START_WORKSPACE: &str = "workspace.start";
    pub const STOP_WORKSPACE: &str = "workspace.stop";
    pub const DELETE_WORKSPACE: &str = "workspace.delete";
    pub const SET_AUTOSTART: &str = "workspace.setAutostart";
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub id: String,
    #[serde(default = "protocol_version")]
    pub version: u32,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

fn protocol_version() -> u32 {
    PROTOCOL_VERSION
}

impl Request {
    pub fn new(id: impl Into<String>, method: impl Into<String>, params: Value) -> Self {
        Self {
            id: id.into(),
            version: PROTOCOL_VERSION,
            method: method.into(),
            params,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub id: String,
    pub version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl Response {
    pub fn success(id: impl Into<String>, result: Value) -> Self {
        Self {
            id: id.into(),
            version: PROTOCOL_VERSION,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(
        id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            version: PROTOCOL_VERSION,
            result: None,
            error: Some(RpcError {
                code: code.into(),
                message: message.into(),
                details: None,
            }),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RpcError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ToolInfo {
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VirtualizationInfo {
    pub provider: Option<String>,
    pub cpu_virtualization: bool,
    pub kvm_device: bool,
    pub kvm_usable: bool,
    pub kvm_api_version: Option<i32>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ResourceProfile {
    pub starting_cpus: u8,
    pub maximum_cpus: u8,
    pub starting_memory_mib: u32,
    pub maximum_memory_mib: u32,
    pub root_disk_mib: u32,
    pub tmpfs_mib: u32,
    pub docker_volume_mib: u32,
    pub network_profile: String,
    #[serde(default)]
    pub dns_servers: Vec<String>,
}

impl Default for ResourceProfile {
    fn default() -> Self {
        Self {
            starting_cpus: 4,
            maximum_cpus: 8,
            starting_memory_mib: 4096,
            maximum_memory_mib: 16384,
            root_disk_mib: 16384,
            tmpfs_mib: 1024,
            docker_volume_mib: 20480,
            network_profile: "all".to_string(),
            dns_servers: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HostInfo {
    pub daemon_version: String,
    pub protocol_version: u32,
    pub hostname: String,
    pub operating_system: String,
    pub operating_system_version: String,
    pub kernel: String,
    pub architecture: String,
    pub cpu_count: u32,
    pub total_memory_mib: u64,
    pub available_memory_mib: u64,
    pub root_disk_total_mib: u64,
    pub root_disk_available_mib: u64,
    pub systemd: bool,
    pub ipv4: bool,
    pub ipv6: bool,
    pub virtualization: VirtualizationInfo,
    pub microsandbox: ToolInfo,
    pub suggested_profile: ResourceProfile,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WorkspaceKind {
    Builder,
    Workspace,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WorkspaceStatus {
    Creating,
    Running,
    Stopped,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    pub generation: u64,
    pub name: String,
    pub runtime_name: String,
    pub kind: WorkspaceKind,
    pub status: WorkspaceStatus,
    pub desired_status: WorkspaceStatus,
    pub template_id: Option<String>,
    pub image: Option<String>,
    pub docker_volume: String,
    pub resources: ResourceProfile,
    pub autostart: bool,
    pub created_at: u64,
    pub updated_at: u64,
    pub last_error: Option<String>,
    #[serde(default)]
    pub tools_installed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Template {
    pub id: String,
    pub generation: u64,
    pub name: String,
    pub snapshot_name: String,
    pub source_workspace_id: String,
    pub resources: ResourceProfile,
    pub created_at: u64,
    pub updated_at: u64,
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateBuilderParams {
    pub name: String,
    #[serde(default = "default_image")]
    pub image: String,
    pub resources: ResourceProfile,
}

fn default_image() -> String {
    "ubuntu:24.04".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceIdParams {
    pub workspace_id: String,
    #[serde(default)]
    pub expected_generation: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishTemplateParams {
    pub workspace_id: String,
    pub name: String,
    #[serde(default)]
    pub expected_generation: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateWorkspaceParams {
    pub template_id: String,
    pub name: String,
    #[serde(default)]
    pub resources: Option<ResourceProfile>,
    #[serde(default)]
    pub autostart: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteWorkspaceParams {
    pub workspace_id: String,
    #[serde(default)]
    pub expected_generation: Option<u64>,
    #[serde(default = "default_true")]
    pub delete_volumes: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetAutostartParams {
    pub workspace_id: String,
    pub autostart: bool,
    #[serde(default)]
    pub expected_generation: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportTemplateParams {
    pub template_id: String,
    #[serde(default)]
    pub output_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteTemplateParams {
    pub template_id: String,
    #[serde(default)]
    pub expected_generation: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportResult {
    pub path: String,
    pub template_id: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_defaults_protocol_version() {
        let request: Request =
            serde_json::from_str(r#"{"id":"1","method":"ping","params":{}}"#).unwrap();
        assert_eq!(request.version, PROTOCOL_VERSION);
    }

    #[test]
    fn responses_have_exactly_one_payload() {
        let success = Response::success("1", serde_json::json!({"ok": true}));
        assert!(success.result.is_some());
        assert!(success.error.is_none());

        let error = Response::error("2", "bad", "bad request");
        assert!(error.result.is_none());
        assert!(error.error.is_some());
    }
}
