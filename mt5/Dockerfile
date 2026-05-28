# gmag11/metatrader5_vnc base, patched to pin mt5linux<1.0 (the version that
# still has the `-w` flag the gmag11 start.sh uses to launch the RPyC server).
#
# gmag11's start.sh unconditionally does `pip install --no-deps mt5linux`
# which resolves to 1.0.3 today — and 1.0.x removed the `-w` switch, so the
# server start fails with "Error: Unknown switch -w". Pinning to <1.0 fixes it.

FROM gmag11/metatrader5_vnc:latest

# Override the broken start.sh with our pinned-mt5linux version.
COPY start.sh /Metatrader/start.sh
USER root
RUN chmod +x /Metatrader/start.sh
