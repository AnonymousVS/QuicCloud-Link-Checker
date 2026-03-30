# QuicCloud-Link-Checker

ตรวจสอบ QUIC.cloud Link Status ของ WordPress ทุกเว็บบนเซิร์ฟเวอร์ cPanel/WHM แบบอัตโนมัติ

## ปัญหาที่แก้

เมื่อติดตั้ง LiteSpeed Cache plugin และ enable QUIC.cloud services แล้ว บางเว็บอาจเลือก **"Stay Anonymous"** ทำให้ยังไม่ได้ link account กับ QUIC.cloud ส่งผลให้:

- ใช้ Online Services ได้จำกัด (quota น้อยกว่า)
- ไม่สามารถดู usage/stats บน QUIC.cloud Dashboard ได้
- ไม่สามารถซื้อ credit เพิ่มได้

Script นี้จะสแกนทุก addon domain บนเซิร์ฟเวอร์ แล้วรายงานว่าเว็บไหนยังไม่ได้ link

## สถานะที่ตรวจสอบ

| สี | สถานะ | ความหมาย |
|:---:|---|---|
| 🔴 | **ANONYMOUS** | Enable QUIC.cloud แล้ว แต่ยังไม่ link account — ต้องกดปุ่ม "Link to QUIC.cloud" |
| 🟡 | **NOT ACTIVATED** | ยังไม่ได้ enable QUIC.cloud เลย |
| 🟢 | **LINKED** | สมบูรณ์แล้ว |

## ข้อกำหนด

- cPanel/WHM server
- LiteSpeed Web Server + LiteSpeed Cache plugin
- Root access (SSH)
- MariaDB / MySQL

## วิธีติดตั้ง

```bash
cd /root
git clone https://github.com/AnonymousVS/QuicCloud-Link-Checker.git
chmod +x QuicCloud-Link-Checker/*.sh
```

## วิธีใช้งาน

### สแกนทั้งเซิร์ฟเวอร์

```bash
bash /root/QuicCloud-Link-Checker/check-quiccloud-link.sh
```

### ทดสอบเว็บเดียว (พร้อม debug ทุก step)

```bash
bash /root/QuicCloud-Link-Checker/test-quiccloud-link.sh example.com
```

## หลักการทำงาน

1. อ่าน `/etc/userdomains` + `/etc/trueuserdomains` เพื่อหา addon domain ทั้งหมด
2. กรองออก: main domain, cPanel subdomain (`*.mainDomain`), `nobody`, `*.cp.*`
3. หา document root (รองรับ 2 path structure):
   - `/home/USERNAME/DOMAIN/`
   - `/home/USERNAME/public_html/DOMAIN/`
4. ตรวจสอบว่ามี WordPress + LiteSpeed Cache plugin
5. อ่าน DB credentials จาก `wp-config.php`
6. Query MySQL ตรง: ดึงค่า `litespeed.cloud._summary` → parse `qc_activated`
7. จัดกลุ่มและแสดงผล

### ทำไมใช้ MySQL แทน WP-CLI?

- **เร็วกว่า** — ไม่ต้อง load WordPress ทั้งตัวทีละเว็บ
- **ไม่มีปัญหา PHP** — lsphp บน cPanel มักแสดง "Only CLI access" เมื่อใช้กับ `sudo -u`
- **ไม่ต้องพึ่ง WP-CLI** — ทำงานได้แม้ wp-cli มีปัญหา

### WordPress Option ที่ตรวจสอบ

```
option_name: litespeed.cloud._summary
```

ค่า `qc_activated` ที่เป็นไปได้:

| ค่า | ความหมาย |
|---|---|
| *(ไม่มี/ว่าง)* | ยังไม่ activate |
| `anonymous` | Enable แล้ว เลือก Stay Anonymous |
| `linked` | Link account แล้ว |
| `cdn` | เปิด QUIC.cloud CDN แล้ว |

## ตัวอย่าง Output

```
═══════════════════════════════════════════════════════════════
  SUMMARY
═══════════════════════════════════════════════════════════════

  Total addon domains scanned:   1500

  ● ANONYMOUS (Need Link):       3
  ● NOT ACTIVATED:               12
  ● LINKED (OK):                 1480
  ● No LiteSpeed Cache plugin:   2
  ● No WordPress:                1
  ● Error/Path not found:        2

═══════════════════════════════════════════════════════════════
  ★ ANONYMOUS — ต้อง Link to QUIC.cloud (3 sites)
═══════════════════════════════════════════════════════════════
  DOMAIN                                   USER                 PATH
  ────────────────────────────────────────────────────────────────────────────────
  iq88bet.net                              jan2026newkey        /home/jan2026newkey/public_html/iq88bet.net
  example123.com                           y2026m02sv01         /home/y2026m02sv01/public_html/example123.com
  testsite.net                             y2026m03sv01         /home/y2026m03sv01/public_html/testsite.net
```

## ข้อมูลอ้างอิง

- ปุ่ม "Link to QUIC.cloud" → PHP function: `Cloud::link_qc()` ในไฟล์ `src/cloud-auth.trait.php`
- Action: `Router::ACTION_CLOUD` + `Cloud::TYPE_LINK`
- WP-CLI: `wp litespeed-online link --email=xxx --api-key=xxx`
- Source: [litespeedtech/lscache_wp](https://github.com/litespeedtech/lscache_wp)

## License

MIT
