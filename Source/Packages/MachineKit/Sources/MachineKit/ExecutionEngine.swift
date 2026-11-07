// Generated from machine-options.json by scripts/generate-machine-options, and the build fails while this differs.

/// `ExecutionEngine`: Run the guest's 64-bit code in the hypervisor engine, with TCG as its other half. Needs a QEMU configured with -Dhvdbt_engine. Apple silicon only.
public enum ExecutionEngine: String, Codable, Sendable {
    case off
    case on
}

/// `MeltdownProtection`: Keep XNU's Meltdown page table switch in code the engine translates. Off skips it, for faster system calls, and the guest loses Meltdown protection. Only the engine reads it.
public enum MeltdownProtection: String, Codable, Sendable {
    case off
    case on
}
