# LuLu Passive Mode Improvements Tests

This directory contains tests for the passive mode FQDN rule creation improvements.

## What's Tested

### 🎯 Domain Name Prioritization
- Prioritizes `flow.URL.host` over `flow.remoteHostname` over `remoteEndpoint.hostname`
- Ensures rules use domain names like `github.com` instead of IP addresses like `140.82.112.3`

### 🎨 Smart Port Display  
- Hides common ports (80, 443) for cleaner UI display
- Shows uncommon ports (8080, 3000, etc.) to highlight important information
- Preserves full data internally for precise filtering

### 🔗 End-to-End Integration
- Validates complete flow from network traffic to final rule display
- Tests real-world scenarios with complex URLs and various port configurations

## Running Tests

```bash
# Run the complete test suite
./run_passive_mode_tests.sh
```

## Test Results

✅ **9/9 tests pass** covering all functionality

### Before/After Examples

| Before (IP-based) | After (Domain-based) |
|------------------|---------------------|
| `140.82.112.3:443` | `github.com` |
| `52.36.184.210:443` | `api.slack.com` |
| `127.0.0.1:8080` | `localhost:8080` |

## Files

- `test_passive_mode_improvements.m` - Comprehensive test suite
- `run_passive_mode_tests.sh` - Build and run script
- `README.md` - This file

## Loopback filter policy tests

Run `sh LuLu/Tests/run_loopback_tests.sh` on macOS. The standalone native tests
compile the actual settings builder, transition coordinator, and preference
implementation. They use a controlled settings-apply callback and isolated
preference files; they do not activate or change the installed firewall.

Coverage includes IPv4 allow-localhost policy precedence, unchanged IPv6 and
external inspection, delayed and failed applies, timeout recovery, start/stop,
profile reloads, failed preference/profile saves, 100 queued transitions, and
40 concurrent preference writers. Builder checks also run with
`NS_BLOCK_ASSERTIONS` defined, so Release configuration cannot disable them.

The optimization applies to IPv4 loopback only. IPv6 keeps LuLu's existing
`FilterData` rule; live IPv6 loopback enforcement was not established on the
macOS test host. These tests do not replace live socket enforcement checks.
