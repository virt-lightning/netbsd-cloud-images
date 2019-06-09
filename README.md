# Build Cloud image for NetBSD

## Usage

- Install NetBSD 8
- Clone the git repository
- Run: `build.sh XXX`
- Done

The final images are in the raw format.

## Notes

- `pkgin` is installed
- the system will start by rebooting 2 times in a row to enlarge the system partition
- the root user is disable, you can enable it with: `usermod -C no root`
