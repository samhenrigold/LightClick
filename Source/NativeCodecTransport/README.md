Experimental native copy transport
==================================

This is the transport experiment for a future native encoder bridge. It calls
no codec APIs and implements no GL commands. It is opt-in; the regular app and
the vendored QEMU, guest kext and OpenCore inputs stay unchanged.

The ARM64 mux implements QEMU's existing private stream-factory ABI. Ordinary
traffic goes to an explicitly selected, unchanged packaged GL executor, with
its existing drain-on-close contract. Only streams starting with the copy
protocol's magic use the copy worker. The mux must forward the delegate's
backing-notification API as well as its ordinary I/O.

The guest opens two existing type-2 userclients: TX submits input/control and
RX receives completions. Each input is copied into one of two bounded slots
before a successful acknowledgement. No guest pointer or temporary QEMU
mapping survives that call. A slot remains unavailable until its result has
been consumed. Shutdown cancels the pair; close waits for the worker.

The first probe holds two patterned 1080p 2vuy inputs, reuses caller memory,
checks third-input backpressure, then releases and drains the worker. FNV-1a
checks every byte for this ownership test; it provides no authentication.
Results are associated by session nonce and job ID, not arrival order.

`DRAIN_ACK` establishes that the worker stopped accessing inputs. It does not
establish guest callback delivery: the receiver separately consumes both
results. No encoder availability, frame-rate improvement, CPU reduction or
media fidelity follows from this test.

Build with `python3 scripts/build-native-codec-copy-probe --output <new-path>
--identity <signing-identity>`. This builds and signs; it never loads or executes
the binaries. The x86_64 probe is guest-only and refuses non-Mavericks kernels.
The host-only unit tests use a fake GL delegate and no graphics/media APIs.

Before a clone test, freeze the mux, guest helper and explicit delegate hashes.
Set `VIM_PASSTHROUGH_OPENGL_INPROCESS_LIBRARY` to the mux and
`LC_COPY_GL_DELEGATE` to the unchanged packaged executor in the clone launcher
environment. Use `probes/native-codec-copy-driver.py` with a new results path,
the exact guest helper and its SHA256. The driver requires an attested enabled
QEMU BQL-release property before staging or running a potentially blocking RX.
No failed or ambiguous request is resent; the harness retires the whole clone.
