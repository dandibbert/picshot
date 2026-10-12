import Darwin
import PicShotTextScriptCore

enum TextScriptResourceLimits {
    /// Fail closed before parsing or evaluating any untrusted request. No attempt is made to
    /// increase an inherited hard limit if this exact contract cannot be installed.
    static func install() throws {
        signal(SIGALRM, SIG_DFL)
        signal(SIGXCPU, SIG_DFL)
        signal(SIGXFSZ, SIG_DFL)
        signal(SIGPIPE, SIG_IGN)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        sigaddset(&unblocked, SIGALRM)
        sigaddset(&unblocked, SIGXCPU)
        sigaddset(&unblocked, SIGXFSZ)
        guard sigprocmask(SIG_UNBLOCK, &unblocked, nil) == 0 else { throw TextScriptDiagnostic.resourceLimitSetup }
        alarm(TextScriptLimits.helperAlarmSeconds)

        try setAndCheck(RLIMIT_CPU, soft: rlim_t(TextScriptLimits.cpuSoftSeconds), hard: rlim_t(TextScriptLimits.cpuHardSeconds))
        try setAndCheck(RLIMIT_FSIZE, soft: 0, hard: 0)
        try setAndCheck(RLIMIT_CORE, soft: 0, hard: 0)
    }

    private static func setAndCheck(_ resource: Int32, soft: rlim_t, hard: rlim_t) throws {
        var requested = rlimit(rlim_cur: soft, rlim_max: hard)
        guard setrlimit(resource, &requested) == 0 else { throw TextScriptDiagnostic.resourceLimitSetup }
        var observed = rlimit()
        guard getrlimit(resource, &observed) == 0,
              observed.rlim_cur == soft, observed.rlim_max == hard else { throw TextScriptDiagnostic.resourceLimitSetup }
    }
}
