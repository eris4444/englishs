# xray-site: سایت + اینباندهای x-ui روی پورت‌های مشترک

روی هر پورت مشترک، HAProxy اولین بایت‌های هر اتصال را نگاه می‌کند:

- **مرورگر** ← سایت (یکی از ۹ قالب آماده، یا سایت خودتان؛ با http و اگر گواهی دارید https)
- **کلاینت VPN** ← اینباند x-ui همان پورت (VMess، VLESS، Trojan، Shadowsocks، TLS، REALITY، WebSocket و ...)

```
اینترنت ──► IP عمومی:2082 ──(روتر)──► سرور:2082 ──► HAProxy ─┬─► سایت (http و https)
                                                              └─► x-ui :123  (Turkey)
```

**x-ui دست نمی‌خورد.** در اپ‌های VPN آدرس = IP عمومی و پورت = پورت عمومی (مثلاً `2082`).

## نصب و به‌روزرسانی

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/eris4444/englishs/claude/admiring-planck-kx3x1l/xray-site/install.sh
```

```bash
sudo bash install.sh
```

نصب برای هر اینباند دو پورت می‌پرسد (پورت اینباند x-ui و پورت عمومی روتر) و بعد قالب سایت را.
اگر قبلاً نصب کرده‌اید، پورت‌ها حفظ می‌شوند و فقط یک بار قالب سایت پرسیده می‌شود (Enter = همان سایت فعلی).
`install.sh` یک فایل کامل است: قالب‌ها داخل خودش هستند و چیز دیگری دانلود نمی‌کند.

به‌روزرسانی‌های بعدی از خود منو: گزینه‌ی **16) Update xray-site**.

## منو (پنل مدیریت)

```bash
sudo xray-site
```

```
  ╭─ Status ───────────────────────────────────────────────
  │ ● splitter    ● website    ● x-ui
  │ Public IP  2.181.79.58        LAN  192.168.100.122
  │ Site       Download center (download)   HTTPS on (vpn.example.com)
  │ SSL        1, next expiry in 82 days
  ╰────────────────────────────────────────────────────────
  ╭─ Ports ────────────────────────────────────────────────
  │ #   public   x-ui inbound              router forwards to        users
  │ 1   2082     123 "Turkey" vmess/tcp    192.168.100.122:2082      3
  │ 2   2083     124 "Germany" vmess/tcp   192.168.100.122:2083      1
  ╰────────────────────────────────────────────────────────

  ── Ports ──────────────────────    ── Website ─────────────────────
    1  Add a port                       5  Choose the site template
    2  Change a port                    6  Edit the site texts
    3  Remove a port                    7  Website internal port
    4  Re-read x-ui and apply
  ── SSL certificates ───────────    ── System ──────────────────────
    8  Get a free certificate          12  Status and connections
    9  Add my own certificate          13  Logs
   10  Manage certificates             14  Restart services
   11  HTTPS for the site              15  Public IP
                                       16  Update xray-site
                                       17  Uninstall
```

(در ترمینال رنگی است. ستون `users` تعداد اتصال‌های فعلی هر پورت است.)

| بخش | کار |
|---|---|
| **1–4 پورت‌ها** | اضافه/تغییر/حذف پورت (فقط دو پورت می‌پرسد). بعد از تغییر اینباند در x-ui گزینه‌ی 4 |
| **5 قالب سایت** | انتخاب از ۹ قالب یا «سایت خودم»؛ هر وقت خواستید عوضش کنید |
| **6 متن‌های سایت** | نام، شعار، ایمیل و تلفن روی سایت (برای هر قالب جدا ذخیره می‌شود) |
| **8 گواهی رایگان** | Let's Encrypt یا ZeroSSL با acme.sh؛ خودکار تمدید می‌شود |
| **9 گواهی خودم** | چسباندن متن گواهی و کلید، یا دادن مسیر فایل‌ها روی سرور |
| **10 مدیریت گواهی‌ها** | تمدید، حذف، نمایش مسیر فایل‌ها برای x-ui، هدایت http به https، ری‌استارت x-ui بعد از تمدید |
| **11 HTTPS سایت** | کدام گواهی(ها) برای https سایت استفاده شوند |

**هر تغییر امن است:** اول بررسی، بعد اعمال، بعد روی همه‌ی پورت‌ها تست؛ اگر چیزی کار نکند تنظیمات قبلی خودکار برمی‌گردد.

## قالب‌های سایت

| # | قالب | توضیح |
|---|---|---|
| 1 | `download` | دانلود سنتر با جست‌وجو و دسته‌بندی |
| 2 | `blog` | وبلاگ شخصی |
| 3 | `company` | سایت شرکت فناوری |
| 4 | `shop` | فروشگاه اینترنتی با سبد خرید |
| 5 | `hosting` | شرکت هاستینگ با تعرفه‌ها |
| 6 | `portfolio` | نمونه‌کار طراح یا عکاس |
| 7 | `soon` | «به‌زودی» با شمارش معکوس |
| 8 | `status` | صفحه‌ی وضعیت سرویس (انگلیسی) |
| 9 | `nginx` | صفحه‌ی پیش‌فرض «Welcome to nginx!» |
| 10 | `custom` | فایل‌های خودتان در `/var/www/xray-site` |

همه‌ی قالب‌ها بدون هیچ فایل خارجی‌اند (سریع، و با فیلتر بودن CDNها هم کامل باز می‌شوند) و روی موبایل هم درست نمایش داده می‌شوند.

## گواهی SSL و HTTPS

**گواهی رایگان (منوی 8):** دامنه باید به IP عمومی شما اشاره کند. دو روش تأیید:

- **Cloudflare DNS (پیشنهادی):** هیچ پورتی لازم نیست باز باشد. دامنه روی Cloudflare باشد و یک API Token
  با دسترسی «Edit zone DNS» بسازید (dash.cloudflare.com ← My Profile ← API Tokens). wildcard (`*.domain`) هم می‌شود.
- **HTTP:** روتر باید پورت عمومی `80` را به یکی از پورت‌های سرور (پیش‌فرض 80) فوروارد کند.

**گواهی خودتان (منوی 9):** متن `-----BEGIN CERTIFICATE-----` و کلید را بچسبانید، یا مسیر فایل‌ها را بدهید.
اسکریپت بررسی می‌کند که کلید مال همان گواهی باشد.

**HTTPS سایت (منوی 11):** بعد از آن `https://دامنه:2082` سایت را با گواهی معتبر نشان می‌دهد، روی همان پورت‌های
مشترک. اتصال‌های TLS با نام‌های دیگر (اینباندهای TLS یا REALITY در x-ui) مثل قبل به x-ui می‌روند. اگر یک اینباند
x-ui از همان دامنه‌ی سایت استفاده کند، اسکریپت قبل از هر تغییری خبر می‌دهد.

**استفاده در x-ui:** منوی 10 ← 3 مسیر فایل‌ها را نشان می‌دهد (مثلاً `/etc/xray-site/certs/vpn.example.com/fullchain.pem`
و `privkey.pem`) تا در تنظیمات پنل x-ui یا TLS اینباند بگذارید. با گزینه‌ی «Restart x-ui after a renewal»،
x-ui بعد از هر تمدید خودکار ری‌استارت می‌شود.

## دستورهای بدون منو

| کار | دستور |
|---|---|
| لیست پورت‌ها | `sudo xray-site list` |
| افزودن / تغییر / حذف | `sudo xray-site add 124 2083` · `change 2083 2084` · `remove 2083` |
| قالب | `sudo xray-site template` · `sudo xray-site template shop` |
| متن‌های سایت | `sudo xray-site site "NAME=فروشگاه من" "EMAIL=me@example.com"` |
| گواهی رایگان | `sudo CF_Token=... xray-site cert issue vpn.example.com --method cloudflare` |
| گواهی خودم | `sudo xray-site cert add mycert /root/cert.pem /root/key.pem --copy` |
| HTTPS سایت | `sudo xray-site cert site vpn.example.com` · `cert site off` · `cert force-https on` |
| وضعیت و لاگ | `sudo xray-site status` · `sudo xray-site logs nginx` |

## نکته‌ها

- محدودیت IP کاربرها در x-ui فقط وقتی کار می‌کند که برای اینباند **Proxy Protocol** را روشن کنید و گزینه‌ی 4 را بزنید.
- برای هر پورت جدید، در **روتر** هم فوروارد بسازید (پورت عمومی ← IP سرور : همان پورت).
- حذف (گزینه‌ی 17) x-ui را دست نمی‌زند و گواهی‌ها را در `/etc/xray-site/certs` نگه می‌دارد.

## برای توسعه

قالب‌ها در `templates/` و کمک‌کننده در `helper.py` هستند؛ بعد از تغییرشان `bash build.sh` آن‌ها را داخل `install.sh` می‌گذارد.
