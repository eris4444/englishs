# سایت + Xray روی یک پورت

با این اسکریپت، nginx روی همان پورتی که روتر به سرور می‌فرستد گوش می‌دهد:

- کسی که `http://IP:8080` را در مرورگر باز کند، **سایت** را می‌بیند.
- کلاینت VPN (‏VLESS + WebSocket روی یک مسیر مخفی) خودکار تشخیص داده می‌شود و nginx آن را به **Xray** می‌دهد.
  Xray فقط روی `127.0.0.1:10000` است و از بیرون دیده نمی‌شود.

```
اینترنت ──► IP عمومی:8080 ──(روتر)──► سرور:1234 ──► nginx ─┬─► سایت  (/var/www/xray-site)
                                                           └─► Xray  (فقط مسیر مخفی + WebSocket)
```

## نصب

روی سرور (Ubuntu/Debian، با دسترسی root):

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/eris4444/englishs/claude/admiring-planck-kx3x1l/xray-site/install.sh
```

```bash
sudo bash install.sh
```

آخر کار، لینک `vless://...` و QR کد چاپ می‌شود. آن را در v2rayNG / Hiddify / v2rayN / Streisand وارد کنید.
همین اطلاعات در `/etc/xray-site/client.txt` هم ذخیره می‌شود.

اگر پورت‌ها فرق دارد:

```bash
sudo SERVER_PORT=1234 PUBLIC_PORT=8080 bash install.sh
```

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `SERVER_PORT` | `1234` | پورتی روی سرور که روتر به آن فوروارد می‌کند |
| `PUBLIC_PORT` | `8080` | پورتی که از اینترنت استفاده می‌شود (در لینک کلاینت) |
| `PUBLIC_IP` | خودکار | IP عمومی؛ اگر درست تشخیص داده نشد دستی بدهید |
| `XRAY_ZIP` | — | اگر سرور به GitHub دسترسی ندارد، فایل `Xray-linux-64.zip` را دستی دانلود کنید و مسیرش را بدهید |
| `ALLOW_LAN` | `0` | با `1`، کاربران VPN به شبکه‌ی خانه (روتر، دستگاه‌های دیگر) هم دسترسی دارند |

اجرای دوباره‌ی اسکریپت امن است: همان UUID و مسیر قبلی حفظ می‌شود و لینک‌های قبلی کار می‌کنند.

## تغییر سایت

فایل‌های سایت در `/var/www/xray-site` است. `index.html` را عوض کنید یا فایل‌های خودتان را آنجا بگذارید؛
نیازی به ری‌استارت نیست. اسکریپت هیچ‌وقت روی `index.html` موجود چیزی نمی‌نویسد.

## دستورهای مفید

```bash
systemctl status xray-site nginx
```

```bash
journalctl -u xray-site -f
```

```bash
cat /etc/xray-site/client.txt
```

## نکته‌ها

- اتصال **بدون TLS** است (چون دامنه و گواهی ندارید). محتوای سایت‌های HTTPS که باز می‌کنید رمز شده است،
  ولی خود تونل قابل تشخیص است. اگر بعداً دامنه گرفتید، می‌شود TLS یا Cloudflare را جلوی همین nginx گذاشت.
- Xray برای WebSocket هشدار «deprecated» در لاگ می‌دهد؛ در نسخه‌ی نصب‌شده (`v26.3.27`) کاملاً کار می‌کند.
  WebSocket انتخاب شد چون همه‌ی کلاینت‌ها آن را پشتیبانی می‌کنند.
- پیش‌فرض، کاربران VPN به `127.0.0.1` و آدرس‌های شبکه‌ی داخلی (`192.168.x.x` و ...) دسترسی ندارند،
  تا کسی که لینک را دارد نتواند وارد پنل روتر شود.

## حذف

```bash
sudo systemctl disable --now xray-site && sudo rm -rf /etc/xray-site /etc/systemd/system/xray-site.service /etc/nginx/conf.d/xray-site.conf && sudo systemctl reload nginx
```
