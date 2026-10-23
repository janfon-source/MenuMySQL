# MenuMySQL 隨手MySQL

A lightweight MySQL and MariaDB manager that lives in the macOS menu bar. Click the menu bar icon to look things up, change data and run SQL; press Esc to put it away. A sibling of [MenuSQLite](https://github.com/janfon-source/MenuSQLite), with the same look and keys.

住在 macOS 選單列的輕量 MySQL／MariaDB 管理工具。[中文說明在下方](#中文說明)。

## Features

- **Connects to MySQL and MariaDB** directly, speaking their protocol itself: nothing else to install. Signs in with `caching_sha2_password` (MySQL 8 and later), `mysql_native_password` and `sha256_password`; uses TLS when the server offers it (or always, or never, as you choose). Without TLS, the SHA-256 password exchange goes encrypted with the server's RSA key.
- **SSH tunnel**: for a server that only takes local connections, tick the tunnel box and give the SSH server (`user@host`, or a Host in `~/.ssh/config`, which fills in its port and key). MenuMySQL forwards a local port with `ssh -N -L` and closes it when you disconnect. Signs in to SSH with keys or ssh-agent; it never asks for an SSH password.
- **Passwords in the keychain**: tick “Save the password” and recent connections open without asking.
- **Switch databases** from the menu at the top of the list; the server's own (`mysql`, `sys`, `information_schema`, `performance_schema`) come last. Create a database (with its character set) or delete one (you type its name to confirm) from the same menu, or ⌘N.
- **Browse** tables and views on the left and their rows on the right; click a header to sort; 200 rows a page. NULLs and BLOBs show dimmed; DECIMALs and dates show exactly as the server writes them.
- **Filter rows** (⌥⌘F): column, comparison (`=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IS NULL`, `IS NOT NULL`, `IS EMPTY`, `IS NOT EMPTY`) and value, joined by AND or OR. The count and paging follow the filter, and the SQL tab starts with the matching SELECT.
- **Edit in place**: double-click a cell to change it, right-click to set it to NULL, add or delete rows with ＋ / −. Rows are found again by the primary key (or a unique index on columns that can't be NULL); tables without one, and views, are read-only.
- **Create and edit tables**: name, type, primary key, not null, unique, AUTO_INCREMENT, default and comment for each column; add, remove, reorder and rename columns and rename the table. The change is one `ALTER TABLE` (shown live as you edit), which keeps data through renames and moves and applies whole or not at all; what you can't see in the grid (collation, `ON UPDATE CURRENT_TIMESTAMP`, generated columns) is kept.
- **Create and edit views**: name, optional column names and the SELECT, with a preview of its first 50 rows (⌘↩). Saving uses `CREATE OR REPLACE VIEW`.
- **Structure**: columns (type, not null, default, key, AUTO_INCREMENT, comments), indexes, row count and the syntax-colored `SHOW CREATE` statement.
- **Run SQL** with ⌘↩: the selection, or everything; several statements at once. Shows the results, rows changed, time taken or the server's error.
- **Structure document (Markdown)** (⇧⌘D): every table and view, with columns, foreign keys (with ON UPDATE / ON DELETE), indexes, triggers, row counts and CREATE statements, rendered in its own window; save, print or open it elsewhere.
- **Database info** (⌘I): server and version, host, SSH tunnel, TLS, the account signed in, character set and collation, number of tables and views, data and index size, unused space; **OPTIMIZE** or **ANALYZE** every table.
- **Import CSV** (⇧⌘I) into the selected table: separator and encoding (UTF-8, UTF-16, Big5, GB18030) worked out from the file, columns matched by name, empty fields as NULL or not, add to the rows or replace them. It runs in one transaction, 500 rows per INSERT, and rolls back on an error.
- **Export CSV** (⇧⌘E), **copy rows** (⌘C), **pinning**, **Dock / menu bar**, **Traditional Chinese / Simplified Chinese / English**, light or dark theme, open at login: as in MenuSQLite.

| Shortcut | Action |
|---|---|
| ⌘O | Connect to a server |
| ⌘N | New database |
| ⌘R | Refresh |
| ⌥⌘N / ⌥⇧⌘N | New table / New view |
| ⌥⌘E | Edit the selected table or view |
| ⇧⌘D | Structure document (Markdown) |
| ⌘1 / ⌘2 / ⌘3 | Data / Structure / SQL tab |
| ⌥⌘F | Filter rows |
| ⌘↩ | Run SQL |
| ⌘I | Database info |
| ⇧⌘I / ⇧⌘E | Import / Export CSV |
| ⌘C | Copy the selected rows |
| Esc | Hide the window |

## Install

Requires macOS 13 or later. Build from source with Xcode or the Command Line Tools (`xcode-select --install`):

```sh
cd MenuMySQLMac
./build.sh install   # builds and installs /Applications/隨手MySQL.app
```

Run `./build.sh` alone to build into `build/隨手MySQL.app` without installing.

## Tests

`tests/run.sh` checks the database layer (signing in with and without TLS, reading and changing rows, ALTER TABLE, views, the structure document, CSV import, reconnecting) against live servers: MySQL on 127.0.0.1:23306 and MariaDB on 127.0.0.1:13306, each with an account `tester` whose password is `p@ss 中文` and which may create the database `menumysql_test`. Give other ports as arguments.

---

## 中文說明

住在 macOS 選單列的輕量 MySQL／MariaDB 管理工具，是[隨手SQLite](https://github.com/janfon-source/MenuSQLite) 的姊妹作，外觀和快速鍵都一樣。點選單列圖示就能查資料、改資料、執行 SQL，按 Esc 收起來。

### 功能

- **直接連線 MySQL 和 MariaDB**：程式自己實作連線協定，不必另外安裝任何東西。支援 `caching_sha2_password`（MySQL 8 以後的預設）、`mysql_native_password`、`sha256_password` 登入；伺服器支援就用 TLS 加密（也可設成一定要用或不用）。沒有 TLS 時，SHA-256 的密碼交換會用伺服器的 RSA 公鑰加密後再送出。
- **SSH 通道**：伺服器只接受本機連線時，勾選「透過 SSH 通道連線」並填 SSH 主機（`user@host`，或 `~/.ssh/config` 裡的 Host，選了會自動帶入連接埠和私鑰）。隨手MySQL 用 `ssh -N -L` 轉接一個本機連接埠，中斷連線時一併關閉。SSH 用金鑰或 ssh-agent 登入，不會詢問 SSH 密碼。
- **密碼存在鑰匙圈**：勾選「把密碼存在鑰匙圈」，之後從最近的連線開啟就不必再輸入。
- **切換資料庫**：資料表清單上方的選單列出伺服器上的資料庫，系統的（`mysql`、`sys`、`information_schema`、`performance_schema`）排在最後；同一個選單也可以新增資料庫（可選字元集）或刪除目前的資料庫（要輸入名稱確認），新增也可以按 ⌘N。
- **瀏覽**：左邊是資料表和視圖，右邊是資料；點欄位標題排序，每頁 200 列。NULL 和 BLOB 以淡色顯示；DECIMAL 和日期照伺服器的寫法完整顯示。
- **篩選資料列**（⌥⌘F）：選欄位、比較方式和值，可以用 AND／OR 加多個條件；列數和分頁跟著篩選，SQL 分頁也會帶出對應的 SELECT。
- **直接編輯**：雙擊儲存格修改，右鍵設為 NULL，狀態列的 ＋／− 新增或刪除資料列。用主鍵（或欄位都不允許 NULL 的唯一索引）找回每一列；沒有這種鍵的資料表和視圖是唯讀的。
- **新增與編輯資料表**：每個欄位的名稱、類型、主鍵、非空、唯一、自動遞增、預設值和註解；可以新增、刪除、調整順序、改名，也能改資料表名稱。變更會組成一個 `ALTER TABLE`（編輯時即時顯示），改名和移動欄位時資料會跟著走，整個成功或整個不做；表格上看不到的設定（定序、`ON UPDATE CURRENT_TIMESTAMP`、產生的欄位）會保留。
- **新增與編輯視圖**：名稱、欄位名稱（選填）和 SELECT，可以預覽前 50 列（⌘↩），儲存時用 `CREATE OR REPLACE VIEW`。
- **結構**：欄位（類型、非空、預設值、主鍵、自動遞增、註解）、索引、資料列數，以及上色的 `SHOW CREATE` 語句。
- **執行 SQL**（⌘↩）：有選取就只執行選取的部分，可以一次執行多個語句；顯示結果、影響列數、花費時間或伺服器的錯誤訊息。
- **結構文件（Markdown）**（⇧⌘D）：所有資料表和視圖的欄位、外鍵（含 ON UPDATE／ON DELETE）、索引、觸發程序、列數和建立語句，在獨立視窗以 Markdown 呈現，可以另存、列印或用其他 App 開啟。
- **資料庫資訊**（⌘I）：伺服器和版本、主機、SSH 通道、TLS、登入帳號、字元集與定序、資料表和視圖數量、資料和索引大小、未使用的空間；可以對所有資料表執行 **OPTIMIZE** 或 **ANALYZE**。
- **匯入 CSV**（⇧⌘I）：自動判斷分隔符號和文字編碼（UTF-8、UTF-16、Big5、GB18030），依名稱對應欄位，可選空白當 NULL、加到現有資料或取代；在同一個交易裡每 500 列一個 INSERT，出錯就整個復原。
- **匯出 CSV**（⇧⌘E）、**拷貝資料列**（⌘C）、**釘選視窗**、**Dock／選單列**、**繁體中文／简体中文／English**、淺色或深色主題、登入時自動開啟：都和隨手SQLite 一樣。

### 安裝

需要 macOS 13 以上。用 Xcode 或 Command Line Tools（`xcode-select --install`）從原始碼編譯：

```sh
cd MenuMySQLMac
./build.sh install   # 編譯並安裝到 /Applications/隨手MySQL.app
```

只執行 `./build.sh` 會編譯到 `build/隨手MySQL.app`，不安裝。

### 測試

`tests/run.sh` 對實際的伺服器檢查資料庫這一層（有無 TLS 的登入、讀寫資料列、ALTER TABLE、視圖、結構文件、CSV 匯入、斷線重連）：MySQL 在 127.0.0.1:23306、MariaDB 在 127.0.0.1:13306，各有帳號 `tester`、密碼 `p@ss 中文`，而且可以建立 `menumysql_test` 資料庫。其他連接埠可以當參數傳入。

## License

MIT
