/// Go's `workbench methodology --json` envelope (cmd/workbench_methodology.go),
/// shared by the Core and the Desktop test targets.
package enum WorkbenchMethodologyFixtures {
    package static let envelope = #"""
        {"id":7,"ok":true,"error":"",
         "personal":{"preset":"","ask_guard":"soft","finish_check":""},
         "effective":{"preset":"watchtower-flow","ask_guard":"soft","finish_check":"off"},
         "sources":{"preset":"default","ask_guard":"personal","finish_check":"file"},
         "file":{"path":".watchtower/workflow.md","present":true,"error":"","body_chars":40,"truncated":false},
         "file_created":false,"file_create_error":"",
         "install_ran":false,"install_ok":true,"install_error":"",
         "install_flow":"","install_codex_flow":"","install_single_file_layout":false}
        """#
}
