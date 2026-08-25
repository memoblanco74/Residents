# نظام إدارة العمارة — نسخة مستقلة (Supabase + GitHub)

هذا المجلد هو نفس التطبيق اللي كان شغال على Google Apps Script / Google Sheets، بعد ما اتنقل بالكامل لـ Supabase عشان يشتغل كـ static site برة بيئة جوجل (GitHub Pages أو أي استضافة ثابتة).

## 1) إنشاء مشروع Supabase
1. اعمل حساب / مشروع جديد على supabase.com (مجاني).
2. من **Project Settings → API** خد:
   - `Project URL`
   - `anon public key`
3. افتح **SQL Editor** والصق فيه محتوى `supabase/schema.sql` بالكامل ونفّذه (Run). ده هيعمل:
   - كل الجداول (residents, announcements, finances, expenses, surveys, maintenance, payment_requests, contacts, tickets, accessories, accessory_requests, settings)
   - RLS مفعّل على الكل
   - كل الدوال (RPC) اللي فيها منطق كان في code.gs (تسجيل الدخول، حماية آخر أدمن، توزيع الدفعات FIFO، حساب الصيانة... إلخ)
   - Storage bucket اسمه `invoices` لمرفقات المصروفات

## 2) تعبئة الجداول
عندك طريقتين، اختار واحدة لكل جدول:

**أ) عن طريق CSV (أسرع لبيانات جاهزة):**
من Supabase → Table Editor → افتح الجدول → Insert → Import data from CSV، وارفع الملف المناسب من `supabase/csv/`:
- `residents.csv` — فيه صف أدمن افتراضي (وحدة `admin`, كلمة السر `admin`). **الباسورد لازم يكون مُشفّر SHA-256 hex** قبل الاستيراد (نفس الطريقة اللي كان بيستخدمها code.gs) — الصف الجاهز فيه هاش كلمة `admin`. لو هتضيف وحدات هنا مباشرة (مش عن طريق لوحة الأدمن) لازم تحسب الهاش بنفس الطريقة، أو الأسهل: اعمل نظام فاضي أول مرة، وسجّل دخول بـ admin/admin، وبعدين استخدم شاشة "الصلاحيات" داخل التطبيق نفسه لإضافة باقي الوحدات (فيها هاش تلقائي).
- `announcements.csv`, `contacts.csv`, `accessories.csv`, `maintenance.csv` — مجرد أمثلة تقدر تعدّلها أو تتجاهلها وتضيف البيانات من داخل التطبيق نفسه بعد ما يشتغل.

**ب) من داخل التطبيق نفسه (الأفضل لكل حاجة فيها منطق: الوحدات، المصروفات، الصيانة، الطلبات...):**
بعد ما تشغّل الموقع (خطوة 3)، سجّل دخول بـ `admin` / `admin`، وأضف كل حاجة من شاشات الأدمن العادية — بالضبط زي ما كنت بتعمل قبل كده، بس دلوقتي بتتسجل في Supabase مش Google Sheets.

## 3) ربط الموقع بالمشروع
افتح `app-supabase.js` وعدّل أول سطرين:
```js
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-PUBLIC-KEY';
```
حطّهم القيم اللي خدتها من خطوة 1. الـ anon key ده **مصمم يتحط في كود الفرونت إند** (زي ما بيحصل في أي مشروع Supabase)، الحماية شغالة من خلال RLS + الدوال في السيرفر مش من إخفاء المفتاح.

## 4) رفعه على GitHub / GitHub Pages
```bash
git init
git add index.html app-supabase.js
git commit -m "Initial commit"
git remote add origin <رابط الريبو بتاعك على GitHub>
git push -u origin main
```
بعدين من إعدادات الريبو: **Settings → Pages → Deploy from branch → main / root**. هيديك رابط زي:
`https://<username>.github.io/<repo>/`

مفيش حاجة تانية محتاجة سيرفر — الملفين دول (`index.html` + `app-supabase.js`) هما التطبيق بالكامل.

## ملاحظات مهمة
- **الفرونت إند اتحرك؟** لأ، `index.html` هو نفسه بالظبط، الحاجة الوحيدة اللي اتضافت هي `google.script.run` بقى "shim" بيكلّم Supabase بدل ما يكلّم Google — فمفيش حاجة اتغيرت في أي زرار أو شاشة.
- **مستوى الأمان:** الجداول (عدا residents) مفتوحة لأي حد معاه الـ anon key، بنفس مستوى الثقة اللي كان في نسخة GAS (أي حد يقدر يفتح الموقع كان يقدر ينادي أي دالة). لو عايز تحسين حقيقي للأمان (منع اليوزر العادي من مناداة دوال الأدمن مباشرة من الـ console)، الخطوة الجاية المنطقية هي إضافة Supabase Auth واستبدال نظام unit/password الحالي بيه — ده تغيير أكبر ومش ضروري للترحيل الأول.
- **جدول residents** محمي بشكل خاص: الباسورد مش قابل للقراءة أبداً من الفرونت إند (حتى بالـ anon key)، وكل الكتابة عليه (إضافة/حذف/تغيير صلاحية/باسورد) بتتم فقط من خلال دوال RPC في السيرفر بتتحقق نفس شروط code.gs (منع حذف آخر أدمن، إلخ).
- **مرفقات المصروفات (الفواتير)** بقت بترفع على Supabase Storage (bucket: `invoices`) بدل Google Drive.
