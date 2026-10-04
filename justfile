# List available commands
default:
    @just --list

# Copy the shared Settings, menu and About code into this app
surfaces:
    python3 .project/mac_surfaces.py sync

# Build RunnerMenu.app; pass debug for a debug build
build config="release": surfaces
    ./build-app.sh {{config}}

# Run the test suite
test:
    ./run-tests.sh
