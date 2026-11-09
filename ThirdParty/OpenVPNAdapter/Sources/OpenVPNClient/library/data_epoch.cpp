// Added for Burrow by Cirtadev GmbH, 2026-11-09: OpenVPN 3 Core 3.11 has one source file besides
// client/ovpncli.cpp (its CMake adds it to every client). Included rather than symlinked so that its
// own #include "data_epoch.hpp" resolves next to it.
#include <openvpn/crypto/data_epoch.cpp>
