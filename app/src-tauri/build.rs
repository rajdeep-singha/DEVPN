fn main() {
    // Request admin privileges on Windows for WireGuard operations
    #[cfg(windows)]
    {
        let mut windows_config = tauri_build::WindowsAttributes::new();
        // Require admin privileges
        windows_config = windows_config.app_manifest(r#"
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
"#);
        tauri_build::try_build(
            tauri_build::Attributes::new().windows_attributes(windows_config)
        ).expect("failed to run tauri build");
    }

    #[cfg(not(windows))]
    {
        tauri_build::build()
    }
}
