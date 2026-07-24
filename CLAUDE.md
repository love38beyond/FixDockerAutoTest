# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **FIX protocol automated testing framework** for Chinese futures exchange trading systems (SHFE/INE exchanges). It uses QuickFIX (Python) to act as a FIX 4.2 initiator, sending trading messages to an exchange FIX gateway and asserting responses against expected values.

## Repository Layout

```
FixAutoTest/FixAutoTest/
├── FixInitiator.py        # Main test runner — the core of the project
├── caselist.txt           # CSV pairs of (config_file, test_case_file) to execute
├── fix42-*.ini            # QuickFIX session configs, one per simulated broker account
├── fix42.xml              # FIX 4.2 data dictionary (customized for Chinese futures)
├── fixautotest.sql        # SQL preconditions (position setup) for test cases
├── testcase/              # Excel (.xlsx) test cases — each file is a test suite
├── initiator/             # QuickFIX FileStore session state files
├── log/                   # QuickFIX message/event logs
├── softpackage/           # Python wheel dependencies (quickfix, xlrd)
├── syslog*.txt            # Test run output logs
└── report.log             # Warning-level log used for pass/fail comparison results
fileExample/               # Reference configs for Dockerized exchange/CTP/FIX containers
docker-fix.txt             # Step-by-step Docker container setup guide for the full system
```

## How to Run

### Dependencies

Python 3.7 with QuickFIX 1.15.1 and xlrd 1.2.0. Install from the bundled wheels:

```bash
cd FixAutoTest/FixAutoTest
pip install softpackage/quickfix-1.15.1-cp37-cp37m-win_amd64.whl
pip install softpackage/xlrd-1.2.0-py2.py3-none-any.whl
```

A Python 3.7 virtualenv (`venv/`) is already set up in the project directory.

### Running tests

```bash
cd FixAutoTest/FixAutoTest
python FixInitiator.py
```

This reads `caselist.txt` and runs every test suite listed. Each line in `caselist.txt` is format: `<config.ini>,<testcase.xlsx>`.

To run a single test case, edit the commented-out code at the bottom of `FixInitiator.py` — uncomment a `main('FIX42-01.ini', 'testcase/orderinsert-00001-1.xlsx')` call and run directly.

### Output

- Console — live test progress and pass/fail for each case
- `syslog.txt` — full run log (INFO level)
- `report.log` — warnings only — captures tag comparison mismatches per case with expected vs actual values
- Terminates with summary: `PASS Case:N, FAIL Case:N, SKIP Case:N`

## Architecture

### Test flow (`FixInitiator.py`)

1. **Load test cases** via `get_confirm_result(path)`: reads an Excel file with two sheets — a "request" sheet (FIX tags to send) and an "expected response" sheet (tags to compare against). Builds two ordered lists: `reqlist` and `rsplist`.

2. **Connect**: Creates a QuickFIX `SocketInitiator` using settings from the `.ini` config file. The custom `MyApplication` class implements `fix.Application`.

3. **Authentication**: On Logon (via `toAdmin`), the script first sends tag 116=12288 (a logon request) with tag 50=<MsgSeqNum> and RawData field, then waits for 116=12289 (logon success) response.

4. **Execute**: Iterates through `reqlist`, dispatching each request to the appropriate message-builder function via `bsfuncdict` (a dict keyed by FIX MsgType → function). Available functions: `NewOrderSingle(D)`, `OrderCancelRequest(F)`, `OrderCancelReplaceRequest(G)`, `OrderStatusRequest(H)`, `MassQuote(i)`, `QuoteCancel(Z)`, `MarketDataRequest(V)`, `NewOrderMultileg(AB)`, `SecurityDefinitionRequest(c)`, `PositionMaintenanceRequest(AL)`.

5. **Assert**: Each response received in `fromApp` is parsed into a tag=value dict and compared against the next expected response in `rsplist` using `compare_two_dict()`. Only specified tags (from the Excel `keylist` column) are compared. Results tracked as PASS/FAIL/SKIP/NOCompare.

### Configuration file format (`.ini`)

Standard QuickFIX initiator session configs. Key settings:
- `SocketConnectHost` — FIX gateway host (typically `10.3.138.139`)  
- `SocketConnectPort` — FIX gateway port (typically `61111`)
- `SenderCompID` — simulated broker ID (00001, 00002, 00003, 4444_admin)
- `TargetCompID` — always `4444` (the exchange)
- `DataDictionary` — `FIX42.xml`

### Test case format (`.xlsx`)

Each Excel file has at minimum two named sheets:
- **Sheet 1** (request): Columns are FIX tag numbers (35, 11, 55, 44, 38, 54, 207, etc.). Row 3 is the header row. Each test step is one row.
- **Sheet 2** (expected response): Same tag-column structure but row values are expected response values. A `keylist` column specifies which tags to compare.

The sheet index and row offset for each step are specified in helper sheets referenced by the first two sheets of the workbook.

### Docker environment (3-tier architecture)

From `docker-fix.txt`, the full test stack runs as three Docker containers:

1. **Exchange container** (`exchangefix`) — the trading exchange core. Runs SSH on ports 26171, 26181. Requires `DeployConfig.xml` and `service.list` IP address replacement.
2. **CTP Trade container** (`ctptradefix`) — CTP trade system front-end. Runs SSH on ports 11157, 11167, 11155. Requires `/etc/hosts` aliases and `DeployConfig.xml` multicast address replacement.
3. **FIX gateway container** (`ctpfix`) — the FIX protocol gateway. Runs SSH on ports 50001, 61111. Requires `fixfront_mt.ini` (trade) and `fixfront_md.ini` (market data) to point at the CTP container's host IP.

All three use `docker import` from tar files (not Dockerfiles), and all require SSH key setup and `setcap cap_net_raw+ep` for ping.

### Key gotchas

- **Python 3.7 only** — the bundled QuickFIX wheel is cp37-specific.
- **Windows platform** — the `.whl` files are for Windows. Path separators in test case loading use `\` (Windows).
- **Tag 116** (OnBehalfOfSubID) is overloaded for message type routing: 12288=logon request, 12289=logon success, 16436=option self-hedge order, 16438=option self-hedge cancel, 16422=position execution report.
- **Global state**: `CTPFrontID`, `CTPSessionID`, and `PosMaintRptID` are module-level globals set from logon/response messages and reused in subsequent requests.
- **Resend avoidance**: The `MyApplication.flag` boolean and PossDupFlag check prevent asserting on replayed/resend messages that would disrupt expected response ordering.
