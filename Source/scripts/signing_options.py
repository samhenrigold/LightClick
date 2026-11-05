"""codesign options for the host binaries of a packaged app."""
import subprocess


def host_options(identity):
    """The hardened runtime always, and the secure timestamp notarization needs on a Developer ID signature.

    Timestamps need Apple's server, so development builds skip them to keep working offline.
    """
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    distribution = any(identity.upper() in line.upper() and 'Developer ID Application' in line
                       for line in identities.splitlines())
    return ['--options', 'runtime', '--timestamp' if distribution else '--timestamp=none']
