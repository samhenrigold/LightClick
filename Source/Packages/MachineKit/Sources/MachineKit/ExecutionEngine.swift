// Generated from machine-options.json by scripts/generate-machine-options, and the build fails while this differs.

/// `ExecutionEngine`, a developer setting with no UI: Run the guest's 64-bit code in the hypervisor engine, with TCG as its other half. Needs a QEMU configured with -Dhvdbt_engine. Apple silicon only.
public enum ExecutionEngine: String, Codable, Sendable {
    case off
    case on
}
