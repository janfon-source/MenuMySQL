# MenuMySQL 隨手MySQL

A lightweight MySQL and MariaDB manager that lives in the macOS menu bar. Click the menu bar icon to look things up, change data and run SQL; press Esc to put it away. A sibling of [MenuSQLite](https://github.com/janfon-source/MenuSQLite), with the same look and keys.

住在 macOS 選單列的輕量 MySQL／MariaDB 管理工具。[中文說明在下方](#中文說明)。

## Features

- **Connects to MySQL and MariaDB** directly, speaking their protocol itself: nothing else to install. Signs in with `caching_sha2_password` (MySQL 8 and later), `mysql_native_password` and `sha256_password`; uses TLS when the server offers it (or always, or never, as you choose). Without TLS, the SHA-256 password exchange goes encrypted with the server's RSA key.
- **Connect through SSH** (choose “Through SSH” at the top of the connection dialog, ⌘O, or go straight there with ⇧⌘O): for a database on a server that only takes connections from the server itself. Give the SSH server (`user@host`, or a Host in `~/.ssh/config`, which fills in its port and key), then the database as that machine sees it (usually `127.0.0.1`), the account and password. MenuMySQL forwards a local port with `ssh -N -L` and closes it when you disconnect. Signs in to SSH with keys or ssh-agent; it never asks for an SSH password.
- **Remembered passwords**: tick “Remember the password” and recent connections and favorites open without asking. Passwords are encrypted (AES-GCM) in `~/Library/Application Support/MenuMySQL`, readable only by your account, so macOS never asks for keychain access, even after an update. Passwords earlier versions saved in the keychain move over the first time they're used.
- **Favorite databases** (“Favorite” in the connection dialog): connect to a favorite in one click. The connection dialog (⌘O) has three choices: Direct (just the database server's fields, no SSH ones), Through SSH, and Favorite, a list of the favorites showing what each connects to, where a click connects (Esc or the Cancel button below it closes the dialog), with a Manage Favorite Databases… button. “Add This Connection to Favorites…” (⌘D) keeps the connection in use, with the database open now, under a name of your own; “Manage Favorite Databases…” lists them to add, duplicate, edit and delete, drag into the order the list shows, and connect (double-click or Connect). Adding and editing use the connection form, with SSH, TLS and the password, plus the name.
- **Several connections at once, in tabs**: each connection (from the connection dialog, a favorite or the recent list) opens in a tab of its own under the toolbar, named after its favorite when it's one, or else its database (hover for the server). Click a tab to switch (⌃Tab / ⌃⇧Tab go to the next and previous), and drag one along the strip to put the tabs in another order; each keeps its table, page, sort, filter, SQL and results as you left them. The same database can be open in several tabs, each on a connection of its own, numbered (2), (3)… from the second. × closes a tab and its connection (and SSH tunnel) with it, as does ⌥⌘W; ＋ connects in a new tab.
- **Switch databases** from the menu at the top of the list; the server's own (`mysql`, `sys`, `information_schema`, `performance_schema`) come last. Create a database (with its character set) or delete one (you type its name to confirm) from the same menu, or ⌘N.
- **Browse** tables and views on the left and their rows on the right; click a header to sort; 200 rows a page. NULLs and BLOBs show dimmed; DECIMALs and dates show exactly as the server writes them.
- **Filter rows** (⌥⌘F): column, comparison (`=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IS NULL`, `IS NOT NULL`, `IS EMPTY`, `IS NOT EMPTY`) and value, joined by AND or OR. The count and paging follow the filter, and the SQL tab starts with the matching SELECT.
- **Choose the columns to show** (the checklist button beside the filter, or ⌥⌘K): a checkbox for each column of the table or view; untick one to hide it, and the menu stays open for the next. All columns show to begin with, and “Show All” brings them back. Each table remembers its choice while the app runs; the status line says how many are hidden, ⌘C copies only the columns shown, and the SQL tab’s SELECT lists them.
- **Reload the rows** (the arrow button under the rows): reads the page showing again, keeping the filter, sort and page, for rows another program or the SQL tab has changed.
- **Export what the Data tab shows** (the share button under the rows): every row the filter lets through, in the sort shown and only the columns showing, to a CSV file, however many rows there are (not just the page of 200). The same button under the SQL tab exports its results: the SELECT written to match the Data tab is run again without its LIMIT 100, and your own SQL's results are written as they show (it isn't run again, as it may change data).
- **Edit in place**: double-click a cell to change it, right-click to set it to NULL, add or delete rows with ＋ / −. Rows are found again by the primary key (or a unique index on columns that can't be NULL); tables without one, and views, are read-only.
- **Create and edit tables**: new tables in a window of their own, existing ones in the **Edit** tab (the first of Edit, Data and SQL), with Save and Revert at its bottom. Name, type and length (in fields of their own: pick `VARCHAR`, give `255`; `DECIMAL` and `10,2`; `ENUM` and `'a','b'`), primary key, not null, unique, AUTO_INCREMENT, default and comment for each column; add, remove, rename and reorder columns (drag a row by its handle, or use the arrows) and rename the table. Once saved, the Edit and Data tabs show the table as it now is. The change is one `ALTER TABLE` (shown live as you edit), which keeps data through renames and moves and applies whole or not at all; what you can't see in the grid (collation, `ON UPDATE CURRENT_TIMESTAMP`, generated columns) is kept. Below the columns, **indexes**: add, change and remove them with a name, a kind (INDEX, UNIQUE, FULLTEXT, SPATIAL) and columns, typed (with a prefix length or DESC, as in `title(20), created DESC`) or ticked from a menu; they follow a column that's renamed, and lose one that's deleted. The key and single-column unique indexes stay the Key and Unique boxes. Drag the grid's column edges to resize them, and hide the fields you don't need (all but the name) with the checklist button at the right; both are remembered. A default typed as plain text gets its single quotes when you leave the field (numbers, NULL, CURRENT_TIMESTAMP and expressions stay as typed).
- **Create and edit views**: in a window for a new view, or the Edit tab for one already there. Name, optional column names and the SELECT, with a preview of its first 50 rows (⌘↩ in the window). Saving uses `CREATE OR REPLACE VIEW`.
- **Table actions**: the gear button at the Edit tab's top right has the table's own actions: OPTIMIZE, ANALYZE, show or copy the CREATE statement, export the table's structure (its facts, columns, indexes and CREATE statement) as Markdown, print it, reset AUTO_INCREMENT to one past the largest value, or set it to a value of your own; or empty the table with TRUNCATE, deleting every row and keeping the table (after asking). Right-clicking a table in the list offers Empty… too.
- **Run SQL** with ⌘↩: the selection, or everything; several statements at once. Shows the results, rows changed, time taken or the server's error.
- **Stays responsive with large data**: reading rows, running SQL, exporting, importing, OPTIMIZE and the structure documents run in the background. After a moment the window shows what's happening (“Loading data…”, “Running the SQL…”), how many rows have arrived and for how long; **Cancel** (or Esc) stops the statement on the server (`KILL QUERY`). Paging and sorting don't count the rows again.
- **Structure document (Markdown)** (⇧⌘D): every table and view, with columns, foreign keys (with ON UPDATE / ON DELETE), indexes, triggers, row counts and CREATE statements, rendered in its own window; save, print or open it elsewhere.
- **Database info** (⌘I): server and version, host, SSH tunnel, TLS, the account signed in, character set and collation, number of tables and views, data and index size, unused space; **OPTIMIZE** or **ANALYZE** every table.
- **Import CSV** (⇧⌘I) into the selected table: separator and encoding (UTF-8, UTF-16, Big5, GB18030) worked out from the file, columns matched by name, empty fields as NULL or not, add to the rows or replace them. It runs in one transaction, 500 rows per INSERT, and rolls back on an error.
- **Export CSV** (⇧⌘E), **copy rows** (⌘C), **pinning**, **Dock / menu bar**, **Traditional Chinese / Simplified Chinese / English**, light or dark theme, open at login: as in MenuSQLite.

| Shortcut | Action |
|---|---|
| ⌘O | Connect to a server |
| ⇧⌘O | Connect through SSH |
| ⌘D | Add this connection to favorites |
| ⌃Tab / ⌃⇧Tab | Next / previous connection tab |
| ⌥⌘W | Close the tab and disconnect |
| ⌘N | New database |
| ⌘R | Refresh |
| ⌥⌘N / ⌥⇧⌘N | New table / New view |
| ⌥⌘E | Edit tab for the selected table or view |
| ⇧⌘D | Structure document (Markdown) |
| ⌘1 / ⌘2 / ⌘3 | Edit / Data / SQL tab |
| ⌥⌘F | Filter rows |
| ⌥⌘K | Choose the columns to show |
| ⌘↩ | Run SQL |
| ⌘I | Database info |
| ⇧⌘I / ⇧⌘E | Import / Export CSV |
| ⌘C | Copy the selected rows |
| Esc | Hide the window |

## Install

Requires macOS 13 or later, on Intel or Apple silicon.

### Download

Paste this into Terminal to download the latest version, install it in Applications and open it:

```sh
curl -L https://github.com/janfon-source/MenuMySQL/releases/latest/download/MenuMySQL.zip -o /tmp/MenuMySQL.zip && ditto -x -k /tmp/MenuMySQL.zip /Applications && open /Applications/隨手MySQL.app
```

Or download the zip from [Releases](https://github.com/janfon-source/MenuMySQL/releases/latest), unzip it and move 隨手MySQL to Applications. The app isn't notarized, so a browser download is blocked the first time: try to open it, click Done at the warning, then click Open Anyway in System Settings → Privacy & Security. The Terminal command above avoids this.

### Build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/janfon-source/MenuMySQL.git
cd MenuMySQL
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
- **透過 SSH 連線**（連線視窗〔⌘O〕上方選「透過 SSH」，或按 ⇧⌘O 直接開啟）：資料庫在只接受本機連線的伺服器上時使用。先填 SSH 主機（`user@host`，或 `~/.ssh/config` 裡的 Host，選了會自動帶入連接埠和私鑰），再填從那台機器看到的資料庫位址（通常是 `127.0.0.1`）、帳號和密碼。隨手MySQL 用 `ssh -N -L` 轉接一個本機連接埠，中斷連線時一併關閉。SSH 用金鑰或 ssh-agent 登入，不會詢問 SSH 密碼。
- **記住密碼**：勾選「記住密碼」，之後從最近的連線或常用資料庫開啟就不必再輸入。密碼以 AES-GCM 加密存在 `~/Library/Application Support/MenuMySQL`，只有你的帳號能讀取，所以不會再跳出鑰匙圈授權，更新版本後也一樣。舊版存在鑰匙圈的密碼，第一次用到時會搬過來。
- **常用資料庫**（連線視窗的「常用資料庫」）：點一下就連上常用的資料庫。連線視窗（⌘O）有三個選項：「直接連線」（只有資料庫伺服器的欄位，沒有 SSH 的欄位）、「透過 SSH」和「常用資料庫」（列出所有常用資料庫和各自連到哪裡，點一下就連線；下方有「管理常用資料庫…」和「取消」按鈕，按 Esc 也會關閉）。「將目前的連線加入常用資料庫…」（⌘D）把目前成功連上的連線和正在使用的資料庫存成自訂名稱；「管理常用資料庫…」可以新增、複製、編輯、刪除，拖曳調整清單裡的順序，雙擊或按「連線」就能連上。新增和編輯用的是連線表單，可設定 SSH、TLS 和密碼，再加上名稱。
- **同時連接多個資料庫，以標籤頁切換**：每個連線（從連線視窗、常用資料庫或最近的連線開啟）都在工具列下方有自己的標籤頁，名稱是常用資料庫裡設定的名稱，不是常用資料庫就顯示資料庫名稱（滑鼠移上去可看主機）。點標籤切換（⌃Tab／⌃⇧Tab 切到下一個／上一個），左右拖曳標籤可以調整前後順序，每個標籤都保留自己的資料表、頁數、排序、篩選、SQL 和查詢結果。同一個資料庫可以在多個標籤頁同時開啟，各自使用獨立的連線，第二個起標上 (2)、(3)…。按 × 或 ⌥⌘W 關閉標籤頁，同時中斷該資料庫的連線（含 SSH 通道）；按 ＋ 在新標籤頁連線。
- **切換資料庫**：資料表清單上方的選單列出伺服器上的資料庫，系統的（`mysql`、`sys`、`information_schema`、`performance_schema`）排在最後；同一個選單也可以新增資料庫（可選字元集）或刪除目前的資料庫（要輸入名稱確認），新增也可以按 ⌘N。
- **瀏覽**：左邊是資料表和視圖，右邊是資料；點欄位標題排序，每頁 200 列。NULL 和 BLOB 以淡色顯示；DECIMAL 和日期照伺服器的寫法完整顯示。
- **篩選資料列**（⌥⌘F）：選欄位、比較方式和值，可以用 AND／OR 加多個條件；列數和分頁跟著篩選，SQL 分頁也會帶出對應的 SELECT。
- **選擇要顯示的欄位**（篩選按鈕旁的清單按鈕，或 ⌥⌘K）：下拉選單列出資料表或視圖的每個欄位，取消勾選就隱藏，選單不會關閉，可以連續調整。預設全部顯示，「全部顯示」可一次恢復。每個資料表的選擇在 App 執行期間都會記住；狀態列會顯示隱藏了幾欄，⌘C 只拷貝顯示中的欄位，SQL 分頁的 SELECT 也只列出這些欄位。
- **重新載入資料**（資料下方的箭頭按鈕）：重新讀取目前這一頁，篩選、排序和頁數不變，用來看其他程式或 SQL 分頁改過的資料。
- **匯出資料畫面的內容**（資料下方的匯出按鈕）：依目前的篩選條件、排序和顯示中的欄位，把全部符合的資料列匯出成 CSV，不受每頁 200 列的限制。SQL 分頁下方的同一個按鈕匯出查詢結果：從資料分頁自動帶入的 SELECT 會拿掉 LIMIT 100 重新查詢；自己寫的 SQL 則匯出畫面上的結果，不會重新執行（以免再次改到資料）。
- **直接編輯**：雙擊儲存格修改，右鍵設為 NULL，狀態列的 ＋／− 新增或刪除資料列。用主鍵（或欄位都不允許 NULL 的唯一索引）找回每一列；沒有這種鍵的資料表和視圖是唯讀的。
- **新增與編輯資料表**：新增資料表在獨立視窗，既有的資料表在「**編輯**」分頁（「編輯」「資料」「SQL」中的第一個）修改，下方有「儲存」和「還原」。每個欄位的名稱、類型和長度（分開設定：選 `VARCHAR`、填 `255`；`DECIMAL` 填 `10,2`；`ENUM` 填 `'a','b'`）、主鍵、非空、唯一、自動遞增、預設值和註解；可以新增、刪除、改名，拖曳左側的把手（或用上下箭頭）調整欄位順序，也能改資料表名稱。儲存後「編輯」和「資料」分頁立即顯示變更後的資料表。變更會組成一個 `ALTER TABLE`（編輯時即時顯示），改名和移動欄位時資料會跟著走，整個成功或整個不做；表格上看不到的設定（定序、`ON UPDATE CURRENT_TIMESTAMP`、產生的欄位）會保留。欄位下方是**索引**：可以新增、修改、刪除，設定名稱、類型（INDEX、UNIQUE、FULLTEXT、SPATIAL）和欄位；欄位可以直接輸入（可加長度或 DESC，例如 `title(20), created DESC`），也可以從選單勾選。欄位改名時索引跟著改，刪除欄位時也會從索引移除。主鍵和單一欄位的唯一索引仍用欄位的「主鍵」「唯一」勾選。表格的欄寬可以拖曳欄位標題的邊界調整，右側的清單按鈕可以取消勾選、隱藏不需要的欄位（名稱除外），兩者都會記住。「預設值」填純文字時，離開欄位後會自動加上單引號（數字、NULL、CURRENT_TIMESTAMP 和運算式維持原樣）。
- **新增與編輯視圖**：新增視圖在獨立視窗，既有的視圖在「編輯」分頁修改。名稱、欄位名稱（選填）和 SELECT，可以預覽前 50 列（在視窗中按 ⌘↩），儲存時用 `CREATE OR REPLACE VIEW`。
- **資料表功能**：「編輯」分頁右上角的齒輪按鈕是這個資料表的功能：最佳化（OPTIMIZE）、分析（ANALYZE）、顯示或複製建立語句（SQL）、把結構（資料表資訊、欄位、索引和建立語句）匯出成 Markdown、列印、把自動遞增值重設為目前最大值加 1，或設成自己指定的值；也可以用 TRUNCATE 清空資料表，刪除所有資料列但保留資料表（會先確認）。在左側清單的資料表上按右鍵也有「清空」。
- **執行 SQL**（⌘↩）：有選取就只執行選取的部分，可以一次執行多個語句；顯示結果、影響列數、花費時間或伺服器的錯誤訊息。
- **大量資料時不卡住**：讀取資料、執行 SQL、匯出、匯入、OPTIMIZE 和產生結構文件都在背景進行。稍等一下視窗就會顯示正在做什麼（「正在讀取資料…」「正在執行 SQL…」）、已讀取多少列和經過幾秒；按**取消**（或 Esc）會請伺服器停止這個語句（`KILL QUERY`）。換頁和排序不再重新計算總列數。
- **結構文件（Markdown）**（⇧⌘D）：所有資料表和視圖的欄位、外鍵（含 ON UPDATE／ON DELETE）、索引、觸發程序、列數和建立語句，在獨立視窗以 Markdown 呈現，可以另存、列印或用其他 App 開啟。
- **資料庫資訊**（⌘I）：伺服器和版本、主機、SSH 通道、TLS、登入帳號、字元集與定序、資料表和視圖數量、資料和索引大小、未使用的空間；可以對所有資料表執行 **OPTIMIZE** 或 **ANALYZE**。
- **匯入 CSV**（⇧⌘I）：自動判斷分隔符號和文字編碼（UTF-8、UTF-16、Big5、GB18030），依名稱對應欄位，可選空白當 NULL、加到現有資料或取代；在同一個交易裡每 500 列一個 INSERT，出錯就整個復原。
- **匯出 CSV**（⇧⌘E）、**拷貝資料列**（⌘C）、**釘選視窗**、**Dock／選單列**、**繁體中文／简体中文／English**、淺色或深色主題、登入時自動開啟：都和隨手SQLite 一樣。

### 安裝

需要 macOS 13 以上，Intel 和 Apple 晶片的 Mac 都可以。

#### 直接下載

在「終端機」貼上這一行，會下載最新版、安裝到「應用程式」並打開：

```sh
curl -L https://github.com/janfon-source/MenuMySQL/releases/latest/download/MenuMySQL.zip -o /tmp/MenuMySQL.zip && ditto -x -k /tmp/MenuMySQL.zip /Applications && open /Applications/隨手MySQL.app
```

也可以到 [Releases](https://github.com/janfon-source/MenuMySQL/releases/latest) 下載壓縮檔，解壓縮後把「隨手MySQL」拖到「應用程式」。隨手MySQL 沒有經過 Apple 公證，用瀏覽器下載的版本第一次打開會被擋下：先打開一次，出現警告後按「完成」，再到「系統設定」→「隱私權與安全性」，在下方按「強制打開」。用上面的終端機指令安裝則不會被擋。

#### 從原始碼編譯

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/janfon-source/MenuMySQL.git
cd MenuMySQL
./build.sh install   # 編譯並安裝到 /Applications/隨手MySQL.app
```

只想編譯不安裝就執行 `./build.sh`，結果在 `build/隨手MySQL.app`。

### 測試

`tests/run.sh` 對實際的伺服器檢查資料庫這一層（有無 TLS 的登入、讀寫資料列、ALTER TABLE、視圖、結構文件、CSV 匯入、斷線重連）：MySQL 在 127.0.0.1:23306、MariaDB 在 127.0.0.1:13306，各有帳號 `tester`、密碼 `p@ss 中文`，而且可以建立 `menumysql_test` 資料庫。其他連接埠可以當參數傳入。

## License

MIT
