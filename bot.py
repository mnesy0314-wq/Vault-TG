import os
import asyncio
import random
import string
import json
import qrcode
import io
import re
from datetime import datetime, timedelta
from telethon import TelegramClient, events, Button
from telethon.sessions import StringSession
from telethon.tl.functions.account import GetPasswordRequest
from telethon.errors import (
    PhoneCodeInvalidError,
    PhoneCodeExpiredError,
    SessionPasswordNeededError,
    FloodWaitError,
    PasswordHashInvalidError,
    UserDeactivatedBanError,
    AuthKeyUnregisteredError,
    PeerFloodError,
)

# ═══════════════════════════════════════
BOT_TOKEN  = "8603489217:AAFXMzjZfMENN3Zv1lMJjmjp3635767d4PE"
API_ID = "2496"
API_HASH = "8da85b0d5bfe62527e5b244c209159c3"
ADMIN_ID   = 8718336414
DATA_FILE  = "accounts.json"
PRICE      = 2.0
CHECK_INTERVAL = 10800  # 3 часа в секундах
# ═══════════════════════════════════════

# ───────────────────────────────────────
# БАЗА ДАННЫХ
# ───────────────────────────────────────
def load_data():
    if not os.path.exists(DATA_FILE):
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "accounts": [],
                "sellers": {},
                "keys": {},        # ключи доступа
                "blocked": [],     # заблокированные продавцы
                "broadcasts": [],  # история рассылок
            }, f, ensure_ascii=False, indent=2)
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        d = json.load(f)
    # Добавляем новые поля если их нет
    for field in ["keys","blocked","broadcasts"]:
        if field not in d:
            d[field] = {} if field == "keys" else []
    if "sellers" not in d: d["sellers"] = {}
    return d

def save_data(data):
    with open(DATA_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def get_acc(idx):
    data = load_data()
    accs = data["accounts"]
    return accs[idx] if 0 <= idx < len(accs) else None

def get_seller(uid):
    data = load_data()
    uid  = str(uid)
    if uid not in data["sellers"]:
        data["sellers"][uid] = {
            "balance": 0.0, "withdraw_req": None,
            "total_sold": 0, "total_uploaded": 0,
            "joined_at": datetime.now().strftime("%d.%m.%Y"),
            "ref_id": None,
        }
        save_data(data)
    return data["sellers"][uid]

def update_seller(uid, updates):
    data = load_data()
    uid  = str(uid)
    if uid not in data["sellers"]:
        get_seller(uid)
        data = load_data()
    data["sellers"][uid].update(updates)
    save_data(data)

def is_blocked(uid):
    return str(uid) in load_data().get("blocked", [])

def is_allowed(uid):
    """Проверяем — есть ли у продавца доступ (активировал ключ или уже в базе)"""
    if uid == ADMIN_ID: return True
    data = load_data()
    return str(uid) in data.get("sellers", {})

def gen_password(n=8):
    return "".join(random.choices(string.ascii_letters + string.digits, k=n))

def gen_key():
    """Генерируем ключ доступа типа VAULT-XXXX-XXXX"""
    part = lambda: "".join(random.choices(string.ascii_uppercase + string.digits, k=4))
    return f"VAULT-{part()}-{part()}"

def bar(cur, total, n=12):
    f = int(n * cur / max(total, 1))
    return "█"*f + "░"*(n-f) + f"  {int(100*cur/max(total,1))}%"

def status_icon(s):
    return {"pending":"🟡","sold":"🟢","dead":"🔴","banned":"⚫","checking":"🔄"}.get(s,"⚪")

def status_text(s):
    return {"pending":"Ожидает","sold":"Принят","dead":"Мёртвый","banned":"Забанен","checking":"Проверка"}.get(s,s)

def hdr(title, icon=""):
    """Красивый заголовок без рамок — работает на мобиле"""
    return f"{icon}  <b>{title}</b>\n{'─'*28}\n\n"

def sep():
    return f"\n{'─'*28}\n\n"

user_states    = {}
code_listeners = {}
qr_sessions    = {}

async def typing(bot, cid, s=0.8):
    async with bot.action(cid, "typing"):
        await asyncio.sleep(s)

# ───────────────────────────────────────
# УСТАНОВИТЬ 2FA
# ───────────────────────────────────────
async def set_2fa(client, password):
    try:
        pwd_info = await client(GetPasswordRequest())
        if pwd_info.has_password:
            return False, "уже установлен"
        await client.edit_2fa(new_password=password)
        return True, "OK"
    except Exception as e:
        return False, str(e)

async def change_2fa(client, old_password, new_password):
    """Меняем существующий 2FA пароль на новый"""
    try:
        await client.edit_2fa(current_password=old_password, new_password=new_password)
        return True, "OK"
    except PasswordHashInvalidError:
        return False, "Неверный текущий пароль"
    except Exception as e:
        return False, str(e)

async def terminate_other_sessions(client):
    """Завершаем все сессии кроме текущей"""
    try:
        from telethon.tl.functions.auth import ResetAuthorizationsRequest
        await client(ResetAuthorizationsRequest())
        return True
    except Exception as e:
        print(f"  ⚠️  terminate_sessions: {e}")
        return False

# ───────────────────────────────────────
# ПРОВЕРКА КАЧЕСТВА АККАУНТА
# ───────────────────────────────────────
async def check_account_quality(client):
    """
    Проверяем:
    - Возраст аккаунта (по ID)
    - Есть ли аватарка
    - Спамблок
    - 2FA
    """
    result = {
        "age":       "Неизвестно",
        "avatar":    False,
        "spamblock": False,
        "twofa":     False,
        "chats":     0,
    }
    try:
        me = await client.get_me()

        # Возраст по Telegram ID
        # ID аккаунта содержит дату регистрации примерно
        tid = me.id
        if tid < 100000000:
            result["age"] = "до 2014"
        elif tid < 400000000:
            result["age"] = "2014-2017"
        elif tid < 800000000:
            result["age"] = "2017-2019"
        elif tid < 1500000000:
            result["age"] = "2019-2021"
        elif tid < 2000000000:
            result["age"] = "2021-2022"
        else:
            result["age"] = "2022+"

        # Аватарка
        photos = await client.get_profile_photos("me", limit=1)
        result["avatar"] = len(photos) > 0

        # Количество диалогов
        dialogs = await client.get_dialogs(limit=50)
        result["chats"] = len(dialogs)

        # Проверка спамблока через @SpamBot
        try:
            async with client.conversation("@SpamBot", timeout=10) as conv:
                await conv.send_message("/start")
                resp = await conv.get_response()
                msg  = resp.text.lower()
                if "free" in msg or "не ограничен" in msg or "no limits" in msg:
                    result["spamblock"] = False
                else:
                    result["spamblock"] = True
        except: pass

        # 2FA
        try:
            pwd = await client(GetPasswordRequest())
            result["twofa"] = pwd.has_password
        except: pass

    except Exception as e:
        print(f"  ⚠️  check_quality: {e}")

    return result

# ───────────────────────────────────────
# АВТОПРОВЕРКА СЕССИЙ (каждые 3 часа)
# ───────────────────────────────────────
async def auto_check(bot):
    while True:
        await asyncio.sleep(CHECK_INTERVAL)
        print(f"\n  🔄  Автопроверка сессий...")
        data    = load_data()
        changed = False
        alive   = 0
        dead    = 0

        for acc in data["accounts"]:
            if acc.get("status") not in ["pending","sold"]:
                continue
            sess = acc.get("session_string","")
            if not sess: continue
            try:
                cl = TelegramClient(StringSession(sess), API_ID, API_HASH)
                await cl.connect()
                ok = await cl.is_user_authorized()
                await cl.disconnect()
            except (UserDeactivatedBanError, AuthKeyUnregisteredError):
                ok = False
            except:
                ok = True  # сеть проблема — не убиваем

            if ok:
                alive += 1
            else:
                if acc.get("status") != "dead":
                    acc["status"] = "dead"
                    acc["died_at"] = datetime.now().strftime("%d.%m.%Y %H:%M")
                    changed = True
                    dead   += 1
                    print(f"  💀  {acc.get('phone')} — умерла")
                    # Уведомляем тебя
                    try:
                        await bot.send_message(ADMIN_ID,
                            f"💀  <b>СЕССИЯ УМЕРЛА</b>\n\n"
                            f"📱  <code>{acc.get('phone','')}</code>\n"
                            f"👤  {acc.get('first_name','')} {acc.get('last_name','')}\n"
                            f"📅  {acc.get('added_at','')}",
                            parse_mode="html"
                        )
                    except: pass
                    # Уведомляем продавца
                    sid = acc.get("seller_id","")
                    if sid:
                        try:
                            await bot.send_message(int(sid),
                                f"⚠️  <b>Аккаунт стал недоступен</b>\n\n"
                                f"📱  <code>{acc.get('phone','')}</code>\n\n"
                                f"Сессия была снята или аккаунт заблокирован.",
                                parse_mode="html"
                            )
                        except: pass

        if changed: save_data(data)
        print(f"  ✅  Проверка: живых={alive} умерло={dead}\n")

        # Отчёт тебе
        try:
            await bot.send_message(ADMIN_ID,
                f"🔄  <b>Автопроверка завершена</b>\n\n"
                f"✅  Живых:  <b>{alive}</b>\n"
                f"💀  Умерло: <b>{dead}</b>",
                parse_mode="html"
            )
        except: pass

# ───────────────────────────────────────
# СЛУШАТЕЛЬ КОДА
# ───────────────────────────────────────
async def listen_for_code(bot, uid, acc_idx, chat_id):
    a = get_acc(acc_idx)
    if not a:
        await bot.send_message(chat_id, "❌  Аккаунт не найден.")
        return
    sess  = a.get("session_string","")
    phone = a.get("phone","")
    twofa = a.get("twofa","")
    if not sess:
        await bot.send_message(chat_id, "❌  Нет сессии.")
        return
    try:
        user_cl = TelegramClient(StringSession(sess), API_ID, API_HASH)
        await user_cl.connect()
        if not await user_cl.is_user_authorized():
            await bot.send_message(chat_id, "❌  Сессия устарела.")
            await user_cl.disconnect()
            return

        code_listeners[phone] = {"uid":uid,"client":user_cl,"chat":chat_id}

        await bot.send_message(chat_id,
            f"╔{'═'*32}╗\n"
            f"║  👂  СЛУШАЮ КОД...            ║\n"
            f"╚{'═'*32}╝\n\n"
            f"📱  <code>{phone}</code>\n\n"
            f"Попробуй войти на любом устройстве\n"
            f"— перехвачу код автоматически!\n\n"
            f"🔐  2FA: <code>{twofa or '—'}</code>\n\n"
            f"<i>⏱  5 минут  |  /cancel_listen</i>",
            parse_mode="html"
        )

        @user_cl.on(events.NewMessage(incoming=True))
        async def on_msg(event):
            msg = event.message.message or ""
            if event.sender_id == 777000:
                codes = re.findall(r'\b\d{5}\b', msg)
                if codes:
                    code = codes[0]
                    await bot.send_message(chat_id,
                        f"╔{'═'*32}╗\n"
                        f"║  ✅  КОД ПЕРЕХВАЧЕН!          ║\n"
                        f"╚{'═'*32}╝\n\n"
                        f"📱  <code>{phone}</code>\n\n"
                        f"🔢  <b>Код:</b>\n"
                        f"┌{'─'*20}┐\n"
                        f"│     <b>{code}</b>\n"
                        f"└{'─'*20}┘\n\n"
                        f"🔐  <b>2FA:</b>\n"
                        f"┌{'─'*20}┐\n"
                        f"│  <code>{twofa or '❌ нет'}</code>\n"
                        f"└{'─'*20}┘\n\n"
                        f"<i>⏱  Действителен 2 минуты</i>",
                        parse_mode="html"
                    )
                    if phone in code_listeners: del code_listeners[phone]
                    await user_cl.disconnect()

        await asyncio.sleep(300)
        if phone in code_listeners:
            del code_listeners[phone]
            await user_cl.disconnect()
            await bot.send_message(chat_id,
                f"⏰  Время вышло для <code>{phone}</code>",
                parse_mode="html",
                buttons=Button.inline("👂  Снова", f"listen_{acc_idx}".encode())
            )
    except Exception as e:
        if phone in code_listeners: del code_listeners[phone]
        await bot.send_message(chat_id, f"❌  Ошибка: <code>{e}</code>", parse_mode="html")

# ───────────────────────────────────────
# СКАН QR АДМИНОМ
# ───────────────────────────────────────
async def process_admin_qr(event, bot, uid, state):
    acc_idx = state.get("acc_index", 0)
    a       = get_acc(acc_idx)
    if not a:
        await event.respond("❌  Аккаунт не найден.")
        return
    sess  = a.get("session_string","")
    phone = a.get("phone","")
    wm    = await event.respond("🔍  <b>Читаю QR...</b>", parse_mode="html")
    try:
        photo_bytes = await event.message.download_media(bytes)
        from PIL import Image
        img_buf = io.BytesIO(photo_bytes)
        img     = Image.open(img_buf)
        qr_data = None
        try:
            import zxingcpp
            result = zxingcpp.read_barcode(img)
            if result: qr_data = result.text
        except ImportError: pass

        if not qr_data:
            await wm.delete()
            await event.respond(
                "❌  <b>Не смог прочитать QR</b>\n\n"
                "Попробуй:\n"
                "• Скриншот с экрана (чётче)\n"
                "• Крупнее QR\n\n"
                "<code>pip install zxing-cpp</code>",
                parse_mode="html"
            )
            return

        await wm.edit("✅  QR прочитан!\n🔄  Авторизуюсь...", parse_mode="html")

        user_cl = TelegramClient(StringSession(sess), API_ID, API_HASH)
        await user_cl.connect()
        if not await user_cl.is_user_authorized():
            await wm.delete()
            await event.respond("❌  Сессия устарела.")
            await user_cl.disconnect()
            return

        import base64
        token_b64 = qr_data.split("token=")[-1]
        padding   = 4 - len(token_b64) % 4
        if padding != 4: token_b64 += "=" * padding
        token = base64.urlsafe_b64decode(token_b64)

        from telethon.tl.functions.auth import AcceptLoginTokenRequest
        await user_cl(AcceptLoginTokenRequest(token=token))
        await wm.delete()
        await event.respond(
            f"╔{'═'*32}╗\n"
            f"║  ✅  QR ВХОД ВЫПОЛНЕН!        ║\n"
            f"╚{'═'*32}╝\n\n"
            f"📱  <code>{phone}</code>\n"
            f"🔐  2FA: <code>{a.get('twofa','—')}</code>",
            parse_mode="html"
        )
        await user_cl.disconnect()
        user_states[uid] = {"step":"idle"}
    except Exception as e:
        await wm.delete()
        await event.respond(f"❌  Ошибка QR: <code>{e}</code>", parse_mode="html")

# ───────────────────────────────────────
# QR ДЛЯ ПРОДАВЦА
# ───────────────────────────────────────
async def generate_seller_qr(event, bot, uid):
    wm = await event.respond("📱  <b>Генерирую QR...</b>", parse_mode="html")
    try:
        temp_cl = TelegramClient(StringSession(), API_ID, API_HASH)
        await temp_cl.connect()
        qr_login = await temp_cl.qr_login()
        qr_url   = qr_login.url

        qr = qrcode.QRCode(version=1, error_correction=qrcode.constants.ERROR_CORRECT_H, box_size=12, border=3)
        qr.add_data(qr_url)
        qr.make(fit=True)
        img = qr.make_image(fill_color="#000000", back_color="#ffffff")
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        buf.name = "qr.png"

        await wm.delete()
        await bot.send_file(
            event.chat_id, buf,
            caption=(
                f"╔{'═'*32}╗\n"
                f"║  📱  ВОЙДИ В АККАУНТ         ║\n"
                f"╚{'═'*32}╝\n\n"
                f"1️⃣  Открой Telegram на телефоне\n"
                f"2️⃣  Настройки → Устройства\n"
                f"3️⃣  Подключить устройство\n"
                f"4️⃣  Наведи камеру на QR\n\n"
                f"<i>⏱  30 секунд</i>"
            ),
            parse_mode="html", force_document=False,
            buttons=[
                [Button.inline("🔄  Новый QR",  b"seller_new_qr")],
                [Button.inline("📱  По номеру", b"sell_add")],
            ]
        )
        qr_sessions[uid] = {"client": temp_cl, "qr_login": qr_login}
        asyncio.create_task(wait_qr_login(bot, uid, temp_cl, qr_login, event.chat_id))
    except Exception as e:
        await wm.delete()
        await event.respond(f"❌  Ошибка QR: <code>{e}</code>", parse_mode="html")

async def wait_qr_login(bot, uid, client, qr_login, chat_id):
    try:
        try:
            await asyncio.wait_for(qr_login.wait(), timeout=60)
        except SessionPasswordNeededError:
            user_states[uid] = {"step":"qr_waiting_2fa","client":client,"chat":chat_id}
            await bot.send_message(chat_id,
                f"╔{'═'*32}╗\n"
                f"║  🔐  НУЖЕН ПАРОЛЬ 2FA        ║\n"
                f"╚{'═'*32}╝\n\n"
                f"✅  QR отсканен!\n\n"
                f"Введи <b>пароль 2FA</b> аккаунта:\n\n"
                f"<i>/cancel — отмена</i>",
                parse_mode="html"
            )
            return

        me   = await client.get_me()
        tid  = me.id
        fn   = me.first_name or ""
        ln   = me.last_name  or ""
        un   = me.username   or ""
        ph   = me.phone      or ""
        dt   = datetime.now().strftime("%d.%m.%Y  %H:%M")
        sess = client.session.save()

        # Проверка дубликата
        data = load_data()
        if any(a.get("phone","").replace(" ","") == ph.replace(" ","") for a in data["accounts"]):
            if uid in qr_sessions: del qr_sessions[uid]
            await bot.send_message(chat_id,
                f"⚠️  <b>Аккаунт уже в базе!</b>\n\n"
                f"📱  <code>{ph}</code>\n\n"
                f"Этот номер уже был залит ранее.",
                parse_mode="html"
            )
            await client.disconnect()
            return

        # Качество аккаунта
        quality = await check_account_quality(client)

        # Ставим 2FA
        new_pass = gen_password(8)
        ok, msg  = await set_2fa(client, new_pass)
        final_2fa = new_pass if ok else ""

        os.makedirs("sessions", exist_ok=True)
        fname = ph.replace("+","").replace(" ","")
        with open(f"sessions/{fname}.txt","w",encoding="utf-8") as f:
            f.write(sess)

        idx = len(data["accounts"])
        data["accounts"].append({
            "user_id":        tid,
            "first_name":     fn,
            "last_name":      ln,
            "username":       un,
            "phone":          ph,
            "twofa":          final_2fa,
            "session_string": sess,
            "added_at":       dt,
            "seller_id":      str(uid),
            "status":         "pending",
            "price":          PRICE,
            "method":         "qr",
            "quality":        quality,
        })
        data["sellers"][str(uid)]["total_uploaded"] = data["sellers"].get(str(uid), {}).get("total_uploaded", 0) + 1
        save_data(data)

        if uid in qr_sessions: del qr_sessions[uid]
        user_states[uid] = {"step":"idle"}

        spam_icon = "🚫" if quality.get("spamblock") else "✅"
        ava_icon  = "🖼" if quality.get("avatar") else "👤"

        await bot.send_message(chat_id,
            f"╔{'═'*32}╗\n"
            f"║  ✅  АККАУНТ ПРИНЯТ!          ║\n"
            f"╚{'═'*32}╝\n\n"
            f"👤  <b>{fn} {ln}</b>\n"
            f"📱  <code>{ph}</code>\n\n"
            f"🔐  <b>2FA:</b> <code>{final_2fa or '❌'}</code>\n\n"
            f"💰  Вознаграждение: <b>${PRICE}</b>\n"
            f"🟡  Ожидает проверки",
            parse_mode="html",
            buttons=[
                [Button.inline("💰  Баланс", b"my_balance")],
                [Button.inline("📋  Мои акки", b"my_accounts")],
            ]
        )

        await bot.send_message(ADMIN_ID,
            f"╔{'═'*32}╗\n"
            f"║  🆕  НОВЫЙ АККАУНТ (QR)!     ║\n"
            f"╚{'═'*32}╝\n\n"
            f"👤  <b>{fn} {ln}</b>\n"
            f"🆔  <code>{tid}</code>\n"
            f"📛  {'@'+un if un else '—'}\n"
            f"📱  <code>{ph}</code>\n"
            f"🔐  2FA: <code>{final_2fa or '❌'}</code>\n"
            f"📅  {dt}\n\n"
            f"{'─'*30}\n\n"
            f"📊  <b>КАЧЕСТВО:</b>\n"
            f"📅  Возраст: <b>{quality.get('age','?')}</b>\n"
            f"{ava_icon}  Аватарка: <b>{'Есть' if quality.get('avatar') else 'Нет'}</b>\n"
            f"{spam_icon}  Спамблок: <b>{'Да' if quality.get('spamblock') else 'Нет'}</b>\n"
            f"💬  Чатов: <b>{quality.get('chats',0)}</b>\n\n"
            f"💾  <code>{sess[:50]}...</code>\n"
            f"👤  Продавец: <code>{uid}</code>",
            parse_mode="html",
            buttons=[
                [Button.inline("✅  Принять",      f"adm_accept_{idx}".encode()),
                 Button.inline("❌  Отклонить",    f"adm_reject_{idx}".encode())],
                [Button.inline("💾  Токен",        f"adm_token_{idx}".encode()),
                 Button.inline("👂  Слушать код",  f"listen_{idx}".encode())],
                [Button.inline("📷  Скан QR",      f"adm_scanqr_{idx}".encode())],
            ]
        )
        print(f"\n  ✅  QR: {ph} | {fn} {ln} | seller={uid}\n")
        await client.disconnect()

    except asyncio.TimeoutError:
        if uid in qr_sessions: del qr_sessions[uid]
        await bot.send_message(chat_id,
            "⏰  <b>QR истёк</b>\n\nПопробуй снова:",
            parse_mode="html",
            buttons=[
                [Button.inline("🔄  Новый QR",  b"seller_new_qr")],
                [Button.inline("📱  По номеру", b"sell_add")],
            ]
        )
        if client.is_connected(): await client.disconnect()
    except Exception as e:
        if uid in qr_sessions: del qr_sessions[uid]
        print(f"  ❌  wait_qr: {e}")
        if client.is_connected(): await client.disconnect()

# ───────────────────────────────────────
# СОХРАНИТЬ АККАУНТ (по коду)
# ───────────────────────────────────────
async def finish_auth(event, bot, uid, client, phone, twofa=""):
    try:
        await typing(bot, event.chat_id, 1.0)
        me   = await client.get_me()
        tid  = me.id
        fn   = me.first_name or ""
        ln   = me.last_name  or ""
        un   = me.username   or ""
        ph   = me.phone      or phone
        dt   = datetime.now().strftime("%d.%m.%Y  %H:%M")

        # Проверка дубликата
        data = load_data()
        if any(a.get("phone","").replace(" ","") == ph.replace(" ","") for a in data["accounts"]):
            await event.respond(
                f"⚠️  <b>Аккаунт уже в базе!</b>\n\n"
                f"📱  <code>{ph}</code>\n\n"
                f"Этот номер уже был залит ранее.",
                parse_mode="html"
            )
            if client.is_connected(): await client.disconnect()
            user_states[uid] = {"step":"idle"}
            return

        pm = await event.respond("⚙️  <b>Обрабатываю...</b>\n" + bar(0,5), parse_mode="html")

        steps = ["Получаю данные","Проверяю качество","Устанавливаю 2FA","Сохраняю сессию","Записываю в базу"]
        for i, s in enumerate(steps, 1):
            await asyncio.sleep(0.4)
            await pm.edit(f"⚙️  <b>{s}...</b>\n{bar(i,5)}", parse_mode="html")

        # Качество
        quality = await check_account_quality(client)

        # 2FA
        final_2fa = twofa
        if not final_2fa:
            new_pass = gen_password(8)
            ok, msg  = await set_2fa(client, new_pass)
            if ok:
                final_2fa = new_pass
            else:
                print(f"  ⚠️  2FA: {msg}")

        sess = client.session.save()
        os.makedirs("sessions", exist_ok=True)
        fname = ph.replace("+","").replace(" ","")
        with open(f"sessions/{fname}.txt","w",encoding="utf-8") as f:
            f.write(sess)

        idx = len(data["accounts"])
        data["accounts"].append({
            "user_id":        tid,
            "first_name":     fn,
            "last_name":      ln,
            "username":       un,
            "phone":          ph,
            "twofa":          final_2fa,
            "session_string": sess,
            "added_at":       dt,
            "seller_id":      str(uid),
            "status":         "pending",
            "price":          PRICE,
            "method":         "code",
            "quality":        quality,
        })
        if str(uid) in data["sellers"]:
            data["sellers"][str(uid)]["total_uploaded"] = data["sellers"][str(uid)].get("total_uploaded",0) + 1
        save_data(data)

        await pm.edit(f"✅  <b>Готово!</b>\n{bar(5,5)}", parse_mode="html")
        await asyncio.sleep(0.3)
        await pm.delete()

        spam_icon = "🚫" if quality.get("spamblock") else "✅"
        ava_icon  = "🖼" if quality.get("avatar") else "👤"

        print(f"\n  ✅  #{idx+1} | {ph} | {fn} {ln} | 2fa={final_2fa}\n")

        await event.respond(
            f"✅  <b>АККАУНТ ПРИНЯТ!</b>\n"
            f"{'─'*28}\n\n"
            f"👤  <b>{fn} {ln}</b>\n"
            f"📱  <code>{ph}</code>\n"
            f"🆔  <code>{tid}</code>\n"
            f"📛  {'@'+un if un else '—'}\n\n"
            f"🔐  <b>Пароль 2FA:</b>  <code>{final_2fa or '❌ не удалось'}</code>\n\n"
            f"💰  Вознаграждение: <b>${PRICE}</b>\n"
            f"🟡  Статус: Ожидает проверки",
            parse_mode="html",
            buttons=[
                [Button.inline("💰  Баланс",     b"my_balance"),
                 Button.inline("📋  Мои акки",   b"my_accounts")],
                [Button.inline("➕  Залить ещё", b"sell_add")],
            ]
        )

        await bot.send_message(ADMIN_ID,
            f"🆕  <b>НОВЫЙ АККАУНТ</b>\n"
            f"{'─'*28}\n\n"
            f"👤  <b>{fn} {ln}</b>\n"
            f"🆔  <code>{tid}</code>\n"
            f"📛  {'@'+un if un else '—'}\n"
            f"📱  <code>{ph}</code>\n"
            f"🔐  2FA: <code>{final_2fa or '❌'}</code>\n"
            f"📅  {dt}\n\n"
            f"📊  <b>Качество:</b>\n"
            f"  Возраст: <b>{quality.get('age','?')}</b>\n"
            f"  Аватарка: <b>{'✅ Есть' if quality.get('avatar') else '❌ Нет'}</b>\n"
            f"  Спамблок: <b>{'🚫 Есть' if quality.get('spamblock') else '✅ Нет'}</b>\n"
            f"  Чатов: <b>{quality.get('chats',0)}</b>\n\n"
            f"👤  Продавец: <code>{uid}</code>",
            parse_mode="html",
            buttons=[
                [Button.inline("✅  Принять",     f"adm_accept_{idx}".encode()),
                 Button.inline("❌  Отклонить",   f"adm_reject_{idx}".encode())],
                [Button.inline("💾  Токен",        f"adm_token_{idx}".encode()),
                 Button.inline("👂  Слушать код",  f"listen_{idx}".encode())],
                [Button.inline("🔄  Сменить 2FA",  f"adm_change2fa_{idx}".encode()),
                 Button.inline("🔌  Сбросить сессии", f"adm_term_{idx}".encode())],
                [Button.inline("📷  Скан QR",      f"adm_scanqr_{idx}".encode())],
            ]
        )

    except Exception as e:
        print(f"  ❌  finish_auth: {e}")
        await event.respond(f"❌  <b>Ошибка:</b>\n<code>{e}</code>", parse_mode="html")
    finally:
        if client.is_connected(): await client.disconnect()
        user_states[uid] = {"step":"idle"}

# ───────────────────────────────────────
# ПАГИНАЦИЯ АККАУНТОВ
# ───────────────────────────────────────
async def send_acc_page(event_or_msg, bot, accs_with_idx, page=0, per_page=5, filter_name=""):
    total     = len(accs_with_idx)
    total_pages = max(1, (total + per_page - 1) // per_page)
    page      = max(0, min(page, total_pages-1))
    start     = page * per_page
    chunk     = accs_with_idx[start:start+per_page]

    header = (
        f"📋  <b>{filter_name or 'ВСЕ АККАУНТЫ'}</b>  —  {total} шт.\n"
        f"Страница {page+1}/{total_pages}\n"
        f"{'─'*32}\n\n"
    )

    # Отправляем каждый аккаунт
    chat_id = event_or_msg.chat_id if hasattr(event_or_msg, 'chat_id') else event_or_msg

    await bot.send_message(chat_id, header, parse_mode="html")

    for real_idx, a in chunk:
        st        = a.get("status","pending")
        quality   = a.get("quality",{})
        spam_icon = "🚫 Есть" if quality.get("spamblock") else "✅ Нет"
        ava_icon  = "✅ Есть" if quality.get("avatar") else "❌ Нет"

        text = (
            f"{status_icon(st)}  <b>#{real_idx+1}  {a.get('first_name','')} {a.get('last_name','')}</b>\n"
            f"├  📱  <code>{a.get('phone','')}</code>\n"
            f"├  🆔  <code>{a.get('user_id','')}</code>\n"
            f"├  📛  {'@'+a['username'] if a.get('username') else '—'}\n"
            f"├  🔐  <code>{a.get('twofa','—')}</code>\n"
            f"├  📅  Возраст: <b>{quality.get('age','?')}</b>\n"
            f"├  🖼  Аватарка: <b>{ava_icon}</b>\n"
            f"├  🚫  Спамблок: <b>{spam_icon}</b>\n"
            f"├  💬  Чатов: <b>{quality.get('chats',0)}</b>\n"
            f"├  👤  Продавец: <code>{a.get('seller_id','')}</code>\n"
            f"└  📆  {a.get('added_at','')}  •  {status_text(st)}"
        )

        btns = [
            [Button.inline("✅  Принять",     f"adm_accept_{real_idx}".encode()),
             Button.inline("❌  Отклонить",   f"adm_reject_{real_idx}".encode())],
            [Button.inline("💾  Токен",       f"adm_token_{real_idx}".encode()),
             Button.inline("👂  Код",         f"listen_{real_idx}".encode())],
            [Button.inline("📷  Скан QR",     f"adm_scanqr_{real_idx}".encode()),
             Button.inline("🚫  Блок прод.",  f"adm_block_{real_idx}".encode())],
        ]
        await bot.send_message(chat_id, text, parse_mode="html", buttons=btns)
        await asyncio.sleep(0.1)

    # Навигация
    nav = []
    if page > 0:
        nav.append(Button.inline("◀️", f"page_{filter_name}_{page-1}".encode()))
    nav.append(Button.inline(f"{page+1}/{total_pages}", b"noop"))
    if page < total_pages-1:
        nav.append(Button.inline("▶️", f"page_{filter_name}_{page+1}".encode()))

    if nav:
        await bot.send_message(chat_id, "Навигация:", buttons=[nav])

# ───────────────────────────────────────
# MAIN
# ───────────────────────────────────────
async def main():
    os.system("cls" if os.name=="nt" else "clear")
    print("╔" + "═"*48 + "╗")
    print("║" + "   🏦   TG VAULT  —  МАРКЕТПЛЕЙС АККАУНТОВ  " + "║")
    print("╚" + "═"*48 + "╝")
    print(f"   ADMIN_ID  : {ADMIN_ID}")
    print(f"   ЦЕНА      : ${PRICE}")
    print(f"   ПРОВЕРКА  : каждые {CHECK_INTERVAL//3600} часа")
    print("─"*50)

    bot  = TelegramClient("vault_session", API_ID, API_HASH)
    await bot.start(bot_token=BOT_TOKEN)
    me   = await bot.get_me()
    data = load_data()
    cnt  = len(data["accounts"])
    print(f"   ✅   @{me.username}")
    print(f"   📦   Аккаунтов: {cnt}")
    print(f"   📨   Жду сообщения...")
    print("─"*50 + "\n")

    asyncio.create_task(auto_check(bot))

    # ════════════════════════════════════
    # /start
    # ════════════════════════════════════
    @bot.on(events.NewMessage(pattern=r"/start(.*)"))
    async def h_start(event):
        uid      = event.sender_id
        is_admin = uid == ADMIN_ID
        try:
            args = event.pattern_match.group(1).strip() if event.pattern_match else ""
        except:
            args = ""

        # Проверка ключа доступа
        if not is_admin and args.startswith("KEY_"):
            key  = args[4:]
            data = load_data()
            keys = data.get("keys",{})
            if key in keys and not keys[key].get("used"):
                # Активируем ключ
                keys[key]["used"]    = True
                keys[key]["used_by"] = uid
                keys[key]["used_at"] = datetime.now().strftime("%d.%m.%Y %H:%M")
                # Создаём продавца
                if str(uid) not in data["sellers"]:
                    data["sellers"][str(uid)] = {
                        "balance":0.0,"withdraw_req":None,
                        "total_sold":0,"total_uploaded":0,
                        "joined_at":datetime.now().strftime("%d.%m.%Y"),
                        "ref_id": None,
                    }
                save_data(data)
                await event.respond(
                    f"✅  <b>Ключ активирован!</b>\n\n"
                    f"Добро пожаловать в TG Vault!\n"
                    f"💰  Цена за аккаунт: <b>${PRICE}</b>",
                    parse_mode="html"
                )
                await bot.send_message(ADMIN_ID,
                    f"🔑  <b>Ключ активирован</b>\n\n"
                    f"👤  ID: <code>{uid}</code>\n"
                    f"🔑  Ключ: <code>{key}</code>",
                    parse_mode="html"
                )
            else:
                await event.respond("❌  <b>Неверный или уже использованный ключ.</b>", parse_mode="html")
                return

        if is_blocked(uid) and not is_admin:
            await event.respond("🚫  <b>Вы заблокированы.</b>", parse_mode="html")
            return

        if not is_allowed(uid) and not is_admin:
            # Может ключ передан текстом (не через ссылку)
            if args and not args.startswith("KEY_"):
                # Проверяем как ключ напрямую
                key  = args.strip()
                data = load_data()
                keys = data.get("keys",{})
                if key in keys and not keys[key].get("used"):
                    keys[key]["used"]    = True
                    keys[key]["used_by"] = uid
                    keys[key]["used_at"] = datetime.now().strftime("%d.%m.%Y %H:%M")
                    if str(uid) not in data["sellers"]:
                        data["sellers"][str(uid)] = {
                            "balance":0.0,"withdraw_req":None,
                            "total_sold":0,"total_uploaded":0,
                            "joined_at":datetime.now().strftime("%d.%m.%Y"),
                            "ref_id":None,
                        }
                    save_data(data)
                    await event.respond("✅  <b>Ключ активирован!</b>\n\n💰  Цена за аккаунт: <b>${PRICE}</b>", parse_mode="html")
                    await bot.send_message(ADMIN_ID, f"🔑  Ключ активирован\n👤  <code>{uid}</code>\n🔑  <code>{key}</code>", parse_mode="html")
                else:
                    await event.respond("❌  <b>Неверный или использованный ключ.</b>", parse_mode="html")
                    return
            else:
                user_states[uid] = {"step":"waiting_key"}
                await event.respond(
                    f"╔{'═'*32}╗\n"
                    f"║  🔒  ЗАКРЫТЫЙ БОТ            ║\n"
                    f"╚{'═'*32}╝\n\n"
                    f"Введи <b>ключ доступа</b>:\n\n"
                    f"Формат: <code>VAULT-XXXX-XXXX</code>",
                    parse_mode="html"
                )
                return

        user_states[uid] = {"step":"idle"}

        if is_admin:
            data  = load_data()
            accs  = data["accounts"]
            pend  = sum(1 for a in accs if a.get("status")=="pending")
            sold  = sum(1 for a in accs if a.get("status")=="sold")
            dead  = sum(1 for a in accs if a.get("status")=="dead")
            earn  = sum(a.get("price",PRICE) for a in accs if a.get("status")=="sold")
            sels  = len(data.get("sellers",{}))
            blk   = len(data.get("blocked",[]))
            await event.respond(
                f"👑  <b>АДМИН ПАНЕЛЬ</b>\n"
                f"{'─'*28}\n\n"
                f"📦  Всего: <b>{len(accs)}</b>  🟡 <b>{pend}</b>  🟢 <b>{sold}</b>  🔴 <b>{dead}</b>\n"
                f"💰  Доход: <b>${earn:.2f}</b>  👥 <b>{sels}</b>  🚫 <b>{blk}</b>",
                buttons=[
                    [Button.inline("📋  Все",         b"adm_all"),
                     Button.inline("🟡  Ожидают",     b"adm_pending")],
                    [Button.inline("🟢  Приняты",     b"adm_sold"),
                     Button.inline("🔴  Мёртвые",     b"adm_dead")],
                    [Button.inline("👥  Продавцы",    b"adm_sellers"),
                     Button.inline("📊  Статистика",  b"adm_stats")],
                    [Button.inline("🔑  Ключи",       b"adm_keys"),
                     Button.inline("📢  Рассылка",    b"adm_broadcast")],
                    [Button.inline("💸  Выводы",      b"adm_withdraws")],
                ],
                parse_mode="html"
            )
        else:
            seller = get_seller(uid)
            await event.respond(
                f"🏦  <b>TG VAULT — ПРОДАЖА</b>\n"
                f"{'─'*28}\n\n"
                f"💰  Цена за аккаунт: <b>${PRICE}</b>\n\n"
                f"📊  Баланс:  <b>${seller['balance']:.2f}</b>\n"
                f"📦  Залито:  <b>{seller.get('total_uploaded',0)}</b>\n"
                f"✅  Принято: <b>{seller.get('total_sold',0)}</b>",
                buttons=[
                    [Button.inline("📱  По номеру", b"sell_add"),
                     Button.inline("📷  По QR",     b"seller_qr")],
                    [Button.inline("📋  Мои акки",  b"my_accounts"),
                     Button.inline("💰  Баланс",    b"my_balance")],
                ],
                parse_mode="html"
            )

    # ════════════════════════════════════
    # КОМАНДЫ
    # ════════════════════════════════════
    @bot.on(events.NewMessage(pattern="/cancel$"))
    async def h_cancel(event):
        uid = event.sender_id
        st  = user_states.get(uid,{})
        cl  = st.get("client")
        if cl and cl.is_connected(): await cl.disconnect()
        if uid in qr_sessions:
            qcl = qr_sessions[uid].get("client")
            if qcl and qcl.is_connected(): await qcl.disconnect()
            del qr_sessions[uid]
        user_states[uid] = {"step":"idle"}
        await event.respond("❌  Отменено. /start — меню",
            buttons=Button.inline("🏠  Меню", b"menu"), parse_mode="html")

    @bot.on(events.NewMessage(pattern="/cancel_listen"))
    async def h_cancel_listen(event):
        uid = event.sender_id
        removed = []
        for phone, info in list(code_listeners.items()):
            if info["uid"] == uid:
                removed.append(phone)
                cl = info.get("client")
                if cl and cl.is_connected(): await cl.disconnect()
        for p in removed: del code_listeners[p]
        await event.respond("⏹  Прослушка остановлена" if removed else "ℹ️  Нет активной прослушки.", parse_mode="html")

    # ════════════════════════════════════
    # CALLBACKS ПРОДАВЦА
    # ════════════════════════════════════
    @bot.on(events.CallbackQuery(data=b"menu"))
    async def cb_menu(event):
        await event.answer()
        uid      = event.sender_id
        is_admin = uid == ADMIN_ID
        if is_blocked(uid) and not is_admin:
            await event.respond("🚫  <b>Вы заблокированы.</b>", parse_mode="html")
            return
        user_states[uid] = {"step":"idle"}
        if is_admin:
            data  = load_data()
            accs  = data["accounts"]
            pend  = sum(1 for a in accs if a.get("status")=="pending")
            sold  = sum(1 for a in accs if a.get("status")=="sold")
            dead  = sum(1 for a in accs if a.get("status")=="dead")
            earn  = sum(a.get("price",PRICE) for a in accs if a.get("status")=="sold")
            sels  = len(data.get("sellers",{}))
            blk   = len(data.get("blocked",[]))
            await event.respond(
                f"╔{'═'*34}╗\n"
                f"║  👑  АДМИН ПАНЕЛЬ             ║\n"
                f"╚{'═'*34}╝\n\n"
                f"📦  Всего: <b>{len(accs)}</b>  │  🟡 <b>{pend}</b>  │  🟢 <b>{sold}</b>  │  🔴 <b>{dead}</b>\n"
                f"💰  Доход: <b>${earn:.2f}</b>  │  👥 <b>{sels}</b>  │  🚫 <b>{blk}</b>",
                buttons=[
                    [Button.inline("📋  Все",         b"adm_all"),
                     Button.inline("🟡  Ожидают",     b"adm_pending")],
                    [Button.inline("🟢  Приняты",     b"adm_sold"),
                     Button.inline("🔴  Мёртвые",     b"adm_dead")],
                    [Button.inline("👥  Продавцы",    b"adm_sellers"),
                     Button.inline("📊  Статистика",  b"adm_stats")],
                    [Button.inline("🔑  Ключи",       b"adm_keys"),
                     Button.inline("📢  Рассылка",    b"adm_broadcast")],
                    [Button.inline("💸  Выводы",      b"adm_withdraws")],
                ],
                parse_mode="html"
            )
        else:
            seller = get_seller(uid)
            await event.respond(
                f"╔{'═'*34}╗\n"
                f"║  🏦  TG VAULT  —  ПРОДАЖА     ║\n"
                f"╚{'═'*34}╝\n\n"
                f"💰  Цена: <b>${PRICE}</b> за аккаунт\n\n"
                f"📊  Баланс:  <b>${seller['balance']:.2f}</b>\n"
                f"📦  Залито:  <b>{seller.get('total_uploaded',0)}</b>\n"
                f"✅  Принято: <b>{seller.get('total_sold',0)}</b>",
                buttons=[
                    [Button.inline("📱  По номеру", b"sell_add"),
                     Button.inline("📷  По QR",     b"seller_qr")],
                    [Button.inline("📋  Мои акки",  b"my_accounts"),
                     Button.inline("💰  Баланс",    b"my_balance")],
                ],
                parse_mode="html"
            )

    @bot.on(events.CallbackQuery(data=b"sell_add"))
    async def cb_sell_add(event):
        uid = event.sender_id
        if is_blocked(uid): return
        user_states[uid] = {"step":"waiting_phone"}
        await event.answer()
        await event.respond(
            f"╔{'═'*32}╗\n"
            f"║  📱  ЗАЛИТЬ ПО НОМЕРУ         ║\n"
            f"╚{'═'*32}╝\n\n"
            f"Введи <b>номер телефона</b>:\n\n"
            f"📌  Формат: <code>+79991234567</code>\n\n"
            f"<i>/cancel — отмена</i>",
            parse_mode="html"
        )

    @bot.on(events.CallbackQuery(data=b"seller_qr"))
    async def cb_seller_qr(event):
        if is_blocked(event.sender_id): return
        await event.answer()
        await generate_seller_qr(event, bot, event.sender_id)

    @bot.on(events.CallbackQuery(data=b"seller_new_qr"))
    async def cb_new_qr(event):
        uid = event.sender_id
        if is_blocked(uid): return
        await event.answer("🔄")
        if uid in qr_sessions:
            qcl = qr_sessions[uid].get("client")
            if qcl and qcl.is_connected(): await qcl.disconnect()
            del qr_sessions[uid]
        await generate_seller_qr(event, bot, uid)

    @bot.on(events.CallbackQuery(data=b"my_balance"))
    async def cb_balance(event):
        await event.answer()
        uid    = event.sender_id
        seller = get_seller(uid)
        bal    = seller.get("balance", 0.0)
        req    = seller.get("withdraw_req")
        await event.respond(
            f"╔{'═'*32}╗\n"
            f"║  💰  БАЛАНС И ВЫВОД           ║\n"
            f"╚{'═'*32}╝\n\n"
            f"💵  Баланс:\n"
            f"┌{'─'*18}┐\n"
            f"│   <b>${bal:.2f}</b>\n"
            f"└{'─'*18}┘\n\n"
            f"📦  Залито:  <b>{seller.get('total_uploaded',0)}</b>\n"
            f"✅  Принято: <b>{seller.get('total_sold',0)}</b>\n\n"
            f"{'⏳  Запрос уже отправлен' if req else ''}",
            buttons=[
                [Button.inline("💸  Запросить вывод", b"withdraw_req")] if bal > 0 and not req else [],
                [Button.inline("◀️  Назад", b"menu")],
            ],
            parse_mode="html"
        )

    @bot.on(events.CallbackQuery(data=b"withdraw_req"))
    async def cb_withdraw(event):
        await event.answer()
        uid    = event.sender_id
        seller = get_seller(uid)
        bal    = seller.get("balance", 0.0)
        if bal <= 0:
            await event.respond("❌  Баланс пустой.", parse_mode="html")
            return
        update_seller(uid, {"withdraw_req": {"amount": bal, "at": datetime.now().strftime("%d.%m.%Y %H:%M")}})
        await event.respond(f"✅  Запрос на вывод <b>${bal:.2f}</b> отправлен!", parse_mode="html")
        await bot.send_message(ADMIN_ID,
            f"╔{'═'*32}╗\n"
            f"║  💸  ЗАПРОС НА ВЫВОД!        ║\n"
            f"╚{'═'*32}╝\n\n"
            f"👤  <code>{uid}</code>\n"
            f"💵  <b>${bal:.2f}</b>\n"
            f"📅  {datetime.now().strftime('%d.%m.%Y %H:%M')}",
            parse_mode="html",
            buttons=[
                [Button.inline("✅  Выплачено",  f"adm_paid_{uid}".encode()),
                 Button.inline("❌  Отклонить",  f"adm_rej_pay_{uid}".encode())],
            ]
        )

    @bot.on(events.CallbackQuery(data=b"my_accounts"))
    async def cb_my_accs(event):
        await event.answer()
        uid  = event.sender_id
        data = load_data()
        accs = [a for a in data["accounts"] if str(a.get("seller_id")) == str(uid)]
        if not accs:
            await event.respond("📭  Нет аккаунтов.",
                buttons=Button.inline("➕  Залить", b"sell_add"), parse_mode="html")
            return
        text = f"📋  <b>Мои аккаунты ({len(accs)}):</b>\n\n"
        for i, a in enumerate(accs, 1):
            st = a.get("status","pending")
            text += (
                f"{status_icon(st)}  <b>#{i}  {a.get('first_name','')} {a.get('last_name','')}</b>\n"
                f"   📱  <code>{a.get('phone','')}</code>\n"
                f"   {status_text(st)}  •  ${a.get('price',PRICE):.2f}\n"
                f"   📅  {a.get('added_at','')}\n\n"
            )
        await event.respond(text, parse_mode="html",
            buttons=Button.inline("➕  Залить ещё", b"sell_add"))

    # ════════════════════════════════════
    # CALLBACKS АДМИНА
    # ════════════════════════════════════
    @bot.on(events.CallbackQuery(data=b"adm_all"))
    async def cb_adm_all(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        accs = list(enumerate(data["accounts"]))
        if not accs:
            await event.respond("📭  Нет аккаунтов.", parse_mode="html"); return
        await send_acc_page(event, bot, accs, 0, filter_name="all")

    @bot.on(events.CallbackQuery(data=b"adm_pending"))
    async def cb_adm_pend(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        accs = [(i,a) for i,a in enumerate(data["accounts"]) if a.get("status")=="pending"]
        if not accs:
            await event.respond("📭  Нет ожидающих.", parse_mode="html"); return
        await send_acc_page(event, bot, accs, 0, filter_name="pending")

    @bot.on(events.CallbackQuery(data=b"adm_sold"))
    async def cb_adm_sold(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        accs = [(i,a) for i,a in enumerate(data["accounts"]) if a.get("status")=="sold"]
        if not accs:
            await event.respond("📭  Нет принятых.", parse_mode="html"); return
        await send_acc_page(event, bot, accs, 0, filter_name="sold")

    @bot.on(events.CallbackQuery(data=b"adm_dead"))
    async def cb_adm_dead(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        accs = [(i,a) for i,a in enumerate(data["accounts"]) if a.get("status")=="dead"]
        if not accs:
            await event.respond("✅  Мёртвых нет!", parse_mode="html"); return
        await send_acc_page(event, bot, accs, 0, filter_name="dead")

    # Пагинация
    @bot.on(events.CallbackQuery(pattern=rb"page_(\w+)_(\d+)"))
    async def cb_page(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        parts  = event.data.decode().split("_")
        fname  = parts[1]
        page   = int(parts[2])
        data   = load_data()
        accs_all = list(enumerate(data["accounts"]))
        if fname == "pending":
            accs = [(i,a) for i,a in accs_all if a.get("status")=="pending"]
        elif fname == "sold":
            accs = [(i,a) for i,a in accs_all if a.get("status")=="sold"]
        elif fname == "dead":
            accs = [(i,a) for i,a in accs_all if a.get("status")=="dead"]
        else:
            accs = accs_all
        await send_acc_page(event, bot, accs, page, filter_name=fname)

    @bot.on(events.CallbackQuery(data=b"adm_stats"))
    async def cb_adm_stats(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data  = load_data()
        accs  = data["accounts"]
        total = len(accs)
        pend  = sum(1 for a in accs if a.get("status")=="pending")
        sold  = sum(1 for a in accs if a.get("status")=="sold")
        dead  = sum(1 for a in accs if a.get("status")=="dead")
        earn  = sum(a.get("price",PRICE) for a in accs if a.get("status")=="sold")
        sels  = data.get("sellers",{})
        # Топ продавцов
        top   = sorted(sels.items(), key=lambda x: x[1].get("total_sold",0), reverse=True)[:5]
        top_text = ""
        for i, (sid, s) in enumerate(top, 1):
            top_text += f"  {i}.  <code>{sid}</code>  —  ✅{s.get('total_sold',0)}  💰${s.get('balance',0):.2f}\n"

        # Сегодня
        today = datetime.now().strftime("%d.%m.%Y")
        today_count = sum(1 for a in accs if a.get("added_at","").startswith(today))

        await event.respond(
            f"╔{'═'*34}╗\n"
            f"║  📊  СТАТИСТИКА               ║\n"
            f"╚{'═'*34}╝\n\n"
            f"📦  Всего:      <b>{total}</b>\n"
            f"🟡  Ожидают:   <b>{pend}</b>\n"
            f"🟢  Приняты:   <b>{sold}</b>\n"
            f"🔴  Мёртвые:   <b>{dead}</b>\n"
            f"📅  Сегодня:   <b>{today_count}</b>\n\n"
            f"💰  Заработано: <b>${earn:.2f}</b>\n"
            f"👥  Продавцов:  <b>{len(sels)}</b>\n\n"
            f"{'─'*36}\n\n"
            f"🏆  <b>ТОП ПРОДАВЦОВ:</b>\n"
            f"{top_text if top_text else '  пусто'}",
            parse_mode="html"
        )

    @bot.on(events.CallbackQuery(data=b"adm_sellers"))
    async def cb_adm_sellers(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data    = load_data()
        sellers = data.get("sellers",{})
        blocked = data.get("blocked",[])
        if not sellers:
            await event.respond("📭  Нет продавцов.", parse_mode="html"); return
        text = f"👥  <b>ПРОДАВЦЫ — {len(sellers)} чел.</b>\n\n"
        for uid, s in sorted(sellers.items(), key=lambda x: x[1].get("total_sold",0), reverse=True):
            blk   = "🚫" if uid in blocked else "✅"
            req   = s.get("withdraw_req")
            text += (
                f"{blk}  <code>{uid}</code>\n"
                f"   ✅{s.get('total_sold',0)}  📦{s.get('total_uploaded',0)}  💰${s.get('balance',0):.2f}\n"
                f"   {'💸 ВЫВОД!' if req else ''}\n\n"
            )
        await event.respond(text, parse_mode="html")

    # 🔑 Ключи доступа
    @bot.on(events.CallbackQuery(data=b"adm_keys"))
    async def cb_adm_keys(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data  = load_data()
        keys  = data.get("keys",{})
        used  = sum(1 for k in keys.values() if k.get("used"))
        fresh = len(keys) - used
        text  = f"🔑  <b>КЛЮЧИ ДОСТУПА</b>\n\n📊  Всего: {len(keys)}  |  ✅ Использовано: {used}  |  🔓 Свежих: {fresh}\n\n"
        for k, v in list(keys.items())[-10:]:  # последние 10
            status = f"✅ {v.get('used_by','?')}" if v.get("used") else "🔓 свободен"
            text += f"<code>{k}</code>  —  {status}\n"
        await event.respond(text, parse_mode="html",
            buttons=[
                [Button.inline("➕  Создать 1 ключ",  b"adm_gen_key1")],
                [Button.inline("➕  Создать 5 ключей", b"adm_gen_key5")],
            ]
        )

    @bot.on(events.CallbackQuery(data=b"adm_gen_key1"))
    async def cb_gen_key1(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        key  = gen_key()
        data["keys"][key] = {"used": False, "created_at": datetime.now().strftime("%d.%m.%Y %H:%M")}
        save_data(data)
        bot_username = (await bot.get_me()).username
        await event.respond(
            f"✅  <b>Новый ключ создан:</b>\n\n"
            f"<code>{key}</code>\n\n"
            f"🔗  Ссылка для продавца:\n"
            f"<code>https://t.me/{bot_username}?start=KEY_{key}</code>\n\n"
            f"<i>Ключ одноразовый!</i>",
            parse_mode="html"
        )

    @bot.on(events.CallbackQuery(data=b"adm_gen_key5"))
    async def cb_gen_key5(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data = load_data()
        bot_username = (await bot.get_me()).username
        text = "✅  <b>5 новых ключей:</b>\n\n"
        for _ in range(5):
            key = gen_key()
            data["keys"][key] = {"used": False, "created_at": datetime.now().strftime("%d.%m.%Y %H:%M")}
            text += f"<code>https://t.me/{bot_username}?start=KEY_{key}</code>\n"
        save_data(data)
        await event.respond(text, parse_mode="html")

    # 📢 Рассылка
    @bot.on(events.CallbackQuery(data=b"adm_broadcast"))
    async def cb_broadcast(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        user_states[ADMIN_ID] = {"step":"waiting_broadcast"}
        await event.respond(
            "📢  <b>РАССЫЛКА</b>\n\n"
            "Напиши сообщение — оно уйдёт всем продавцам:\n\n"
            "<i>/cancel — отмена</i>",
            parse_mode="html"
        )

    # 💸 Все выводы
    @bot.on(events.CallbackQuery(data=b"adm_withdraws"))
    async def cb_withdraws(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        data    = load_data()
        sellers = data.get("sellers",{})
        reqs    = [(uid, s["withdraw_req"]) for uid, s in sellers.items() if s.get("withdraw_req")]
        if not reqs:
            await event.respond("✅  Нет запросов на вывод.", parse_mode="html"); return
        text = f"💸  <b>ЗАПРОСЫ НА ВЫВОД — {len(reqs)} шт.</b>\n\n"
        for uid, req in reqs:
            text += f"👤  <code>{uid}</code>  —  <b>${req.get('amount',0):.2f}</b>  ({req.get('at','')})\n"
        await event.respond(text, parse_mode="html",
            buttons=[[Button.inline(f"✅  Выплатить {uid}", f"adm_paid_{uid}".encode())] for uid, _ in reqs[:5]]
        )

    # ✅ Принять
    @bot.on(events.CallbackQuery(pattern=rb"adm_accept_(\d+)"))
    async def cb_accept(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("✅")
        idx  = int(event.data.decode().split("_")[-1])
        data = load_data()
        if idx >= len(data["accounts"]): return
        acc = data["accounts"][idx]
        if acc.get("status") == "sold":
            await event.respond("ℹ️  Уже принят."); return
        acc["status"] = "sold"
        sid   = str(acc.get("seller_id",""))
        price = acc.get("price", PRICE)
        if sid:
            if sid in data["sellers"]:
                data["sellers"][sid]["balance"]    += price
                data["sellers"][sid]["total_sold"] += 1
            else:
                data["sellers"][sid] = {"balance":price,"withdraw_req":None,"total_sold":1,"total_uploaded":1,"joined_at":datetime.now().strftime("%d.%m.%Y")}
        save_data(data)
        await event.respond(f"✅  <b>#{idx+1} принят!</b>\n💰  Продавцу: <b>${price:.2f}</b>", parse_mode="html")
        if sid:
            try:
                await bot.send_message(int(sid),
                    f"✅  <b>Аккаунт принят!</b>\n📱  <code>{acc.get('phone','')}</code>\n💰  <b>+${price:.2f}</b>",
                    parse_mode="html", buttons=Button.inline("💸  Вывести", b"my_balance"))
            except: pass

    # ❌ Отклонить
    @bot.on(events.CallbackQuery(pattern=rb"adm_reject_(\d+)"))
    async def cb_reject(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("❌")
        idx  = int(event.data.decode().split("_")[-1])
        data = load_data()
        if idx >= len(data["accounts"]): return
        acc = data["accounts"][idx]
        acc["status"] = "dead"
        sid = str(acc.get("seller_id",""))
        save_data(data)
        await event.respond(f"❌  <b>#{idx+1} отклонён</b>", parse_mode="html")
        if sid:
            try:
                await bot.send_message(int(sid),
                    f"❌  Аккаунт не принят\n📱  <code>{acc.get('phone','')}</code>\n\nПопробуй другой.",
                    parse_mode="html", buttons=Button.inline("➕  Залить", b"sell_add"))
            except: pass

    # 💾 Токен
    @bot.on(events.CallbackQuery(pattern=rb"adm_token_(\d+)"))
    async def cb_token(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("💾")
        idx = int(event.data.decode().split("_")[-1])
        a   = get_acc(idx)
        if not a: return
        await event.respond(
            f"╔{'═'*32}╗\n"
            f"║  💾  SESSION STRING #{idx+1}         ║\n"
            f"╚{'═'*32}╝\n\n"
            f"📱  <code>{a.get('phone','')}</code>\n"
            f"🔐  2FA: <code>{a.get('twofa','—')}</code>\n\n"
            f"<code>{a.get('session_string','')}</code>",
            parse_mode="html"
        )

    # 👂 Слушать код
    @bot.on(events.CallbackQuery(pattern=rb"listen_(\d+)"))
    async def cb_listen(event):
        await event.answer("👂")
        idx = int(event.data.decode().split("_")[1])
        asyncio.create_task(listen_for_code(bot, event.sender_id, idx, event.chat_id))

    # 📷 Скан QR (админ)
    @bot.on(events.CallbackQuery(pattern=rb"adm_scanqr_(\d+)"))
    async def cb_scanqr(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("📷")
        idx = int(event.data.decode().split("_")[-1])
        a   = get_acc(idx)
        if not a: return
        user_states[ADMIN_ID] = {"step":"waiting_admin_qr","acc_index":idx}
        await event.respond(
            f"📷  <b>СКАН QR</b>\n"
            f"{'─'*28}\n\n"
            f"📱  <code>{a.get('phone','')}</code>\n\n"
            f"Отправь <b>скриншот с QR кодом</b>\n\n"
            f"<i>/cancel — отмена</i>",
            parse_mode="html"
        )

    # 🔄 Сменить 2FA
    @bot.on(events.CallbackQuery(pattern=rb"adm_change2fa_(\d+)"))
    async def cb_change2fa(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("🔄")
        idx = int(event.data.decode().split("_")[-1])
        a   = get_acc(idx)
        if not a: return
        sess = a.get("session_string","")
        if not sess:
            await event.respond("❌  Нет сессии.", parse_mode="html")
            return
        old_2fa = a.get("twofa","")
        wm = await event.respond(
            f"🔄  <b>Меняю 2FA пароль...</b>\n\n"
            f"📱  <code>{a.get('phone','')}</code>",
            parse_mode="html"
        )
        try:
            cl = TelegramClient(StringSession(sess), API_ID, API_HASH)
            await cl.connect()
            if not await cl.is_user_authorized():
                await wm.edit("❌  Сессия устарела.", parse_mode="html")
                await cl.disconnect()
                return
            new_pass = gen_password(8)
            if old_2fa:
                ok, msg = await change_2fa(cl, old_2fa, new_pass)
            else:
                ok, msg = await set_2fa(cl, new_pass)
            if ok:
                # Обновляем в базе
                data = load_data()
                data["accounts"][idx]["twofa"] = new_pass
                save_data(data)
                await wm.edit(
                    f"✅  <b>2FA изменён!</b>\n\n"
                    f"📱  <code>{a.get('phone','')}</code>\n\n"
                    f"🔐  Старый: <code>{old_2fa or '—'}</code>\n"
                    f"🔐  Новый:  <code>{new_pass}</code>",
                    parse_mode="html"
                )
                print(f"  ✅  2FA изменён: {a.get('phone')} | {old_2fa} → {new_pass}")
            else:
                await wm.edit(f"❌  Ошибка смены 2FA: <code>{msg}</code>", parse_mode="html")
            await cl.disconnect()
        except Exception as e:
            await wm.edit(f"❌  Ошибка: <code>{e}</code>", parse_mode="html")

    # 🔌 Завершить все сессии (кроме нашей)
    @bot.on(events.CallbackQuery(pattern=rb"adm_term_(\d+)"))
    async def cb_terminate(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer("🔌")
        idx = int(event.data.decode().split("_")[-1])
        a   = get_acc(idx)
        if not a: return
        sess = a.get("session_string","")
        if not sess:
            await event.respond("❌  Нет сессии.", parse_mode="html")
            return
        wm = await event.respond(
            f"🔌  <b>Завершаю все сессии...</b>\n\n"
            f"📱  <code>{a.get('phone','')}</code>",
            parse_mode="html"
        )
        try:
            cl = TelegramClient(StringSession(sess), API_ID, API_HASH)
            await cl.connect()
            if not await cl.is_user_authorized():
                await wm.edit("❌  Сессия устарела.", parse_mode="html")
                await cl.disconnect()
                return
            ok = await terminate_other_sessions(cl)
            if ok:
                await wm.edit(
                    f"✅  <b>Все сессии завершены!</b>\n\n"
                    f"📱  <code>{a.get('phone','')}</code>\n\n"
                    f"Остался только бот.\n"
                    f"Никто другой не может войти.",
                    parse_mode="html"
                )
                print(f"  ✅  Сессии сброшены: {a.get('phone')}")
            else:
                await wm.edit("❌  Не удалось завершить сессии.", parse_mode="html")
            await cl.disconnect()
        except Exception as e:
            await wm.edit(f"❌  Ошибка: <code>{e}</code>", parse_mode="html")

    # 🚫 Заблокировать продавца
    @bot.on(events.CallbackQuery(pattern=rb"adm_block_(\d+)"))
    async def cb_block(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        idx = int(event.data.decode().split("_")[-1])
        a   = get_acc(idx)
        if not a: return
        sid  = str(a.get("seller_id",""))
        data = load_data()
        if sid and sid not in data["blocked"]:
            data["blocked"].append(sid)
            save_data(data)
            await event.respond(f"🚫  Продавец <code>{sid}</code> заблокирован.", parse_mode="html")
            try:
                await bot.send_message(int(sid), "🚫  <b>Вы заблокированы.</b>", parse_mode="html")
            except: pass
        else:
            await event.respond("ℹ️  Уже заблокирован.", parse_mode="html")

    # 💸 Выплатить
    @bot.on(events.CallbackQuery(pattern=rb"adm_paid_(\d+)"))
    async def cb_paid(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        sid    = int(event.data.decode().split("_")[-1])
        seller = get_seller(sid)
        amount = seller.get("balance", 0)
        update_seller(sid, {"balance":0,"withdraw_req":None})
        await event.respond(f"✅  Выплата <b>${amount:.2f}</b> → <code>{sid}</code>", parse_mode="html")
        try:
            await bot.send_message(sid,
                f"✅  <b>ВЫПЛАТА ${amount:.2f}</b>\n\nЗаливай ещё! 💪",
                parse_mode="html", buttons=Button.inline("➕  Залить", b"sell_add"))
        except: pass

    # ❌ Отклонить вывод
    @bot.on(events.CallbackQuery(pattern=rb"adm_rej_pay_(\d+)"))
    async def cb_rej_pay(event):
        if event.sender_id != ADMIN_ID: return
        await event.answer()
        sid = int(event.data.decode().split("_")[-1])
        update_seller(sid, {"withdraw_req":None})
        await event.respond(f"❌  Вывод отклонён.", parse_mode="html")
        try:
            await bot.send_message(sid, "❌  Запрос на вывод отклонён.", parse_mode="html")
        except: pass

    @bot.on(events.CallbackQuery(data=b"noop"))
    async def cb_noop(event):
        await event.answer()

    # ════════════════════════════════════
    # FSM
    # ════════════════════════════════════
    @bot.on(events.NewMessage)
    async def h_msg(event):
        if event.text and event.text.startswith("/"): return

        uid   = event.sender_id
        text  = event.text.strip() if event.text else ""
        state = user_states.get(uid, {"step":"idle"})
        step  = state.get("step","idle")
        print(f"  [{step}]  {uid}:  {text or '[медиа]'}")

        # ── РАССЫЛКА ──
        if step == "waiting_broadcast" and uid == ADMIN_ID:
            data    = load_data()
            sellers = data.get("sellers",{})
            sent    = 0
            failed  = 0
            pm = await event.respond(f"📢  Рассылаю {len(sellers)} продавцам...", parse_mode="html")
            for sid in sellers:
                try:
                    await bot.send_message(int(sid),
                        f"📢  <b>Сообщение от администратора:</b>\n\n{text}",
                        parse_mode="html"
                    )
                    sent += 1
                    await asyncio.sleep(0.3)
                except:
                    failed += 1
            await pm.edit(
                f"✅  <b>Рассылка завершена!</b>\n\n"
                f"📨  Отправлено: <b>{sent}</b>\n"
                f"❌  Ошибок:    <b>{failed}</b>",
                parse_mode="html"
            )
            user_states[uid] = {"step":"idle"}
            return

        # ── ФОТО QR (АДМИН) ──
        if step == "waiting_admin_qr" and uid == ADMIN_ID:
            if event.message.photo or event.message.document:
                await process_admin_qr(event, bot, uid, state)
            else:
                await event.respond("📷  Нужно фото с QR!", parse_mode="html")
            return

        # ── ВВОД КЛЮЧА ДОСТУПА ──
        if step == "waiting_key":
            key  = text.strip()
            data = load_data()
            keys = data.get("keys",{})
            if key in keys and not keys[key].get("used"):
                keys[key]["used"]    = True
                keys[key]["used_by"] = uid
                keys[key]["used_at"] = datetime.now().strftime("%d.%m.%Y %H:%M")
                if str(uid) not in data["sellers"]:
                    data["sellers"][str(uid)] = {
                        "balance":0.0,"withdraw_req":None,
                        "total_sold":0,"total_uploaded":0,
                        "joined_at":datetime.now().strftime("%d.%m.%Y"),
                        "ref_id":None,
                    }
                save_data(data)
                user_states[uid] = {"step":"idle"}
                await event.respond(
                    f"✅  <b>Ключ активирован!</b>\n\n"
                    f"Добро пожаловать в TG Vault!\n"
                    f"💰  Цена за аккаунт: <b>${PRICE}</b>",
                    parse_mode="html",
                    buttons=[
                        [Button.inline("📱  Залить по номеру", b"sell_add")],
                        [Button.inline("📷  Залить по QR",     b"seller_qr")],
                    ]
                )
                await bot.send_message(ADMIN_ID,
                    f"🔑  Ключ активирован\n👤  <code>{uid}</code>\n🔑  <code>{key}</code>",
                    parse_mode="html"
                )
            else:
                await event.respond(
                    "❌  <b>Неверный или использованный ключ!</b>\n\nПопробуй ещё раз:",
                    parse_mode="html"
                )
            return

        # ── НОМЕР ТЕЛЕФОНА ──
        if step == "waiting_phone":
            if is_blocked(uid): return
            phone = text.replace(" ","").replace("-","")
            if not phone.startswith("+") or not phone[1:].isdigit() or len(phone) < 11:
                await event.respond("❌  Неверный формат!\n\n<code>+79991234567</code>", parse_mode="html")
                return
            wm = await event.respond(f"⏳  Отправляю код на <code>{phone}</code>...", parse_mode="html")
            try:
                client = TelegramClient(StringSession(), API_ID, API_HASH)
                await client.connect()
                result = await client.send_code_request(phone)
                user_states[uid] = {"step":"waiting_code","phone":phone,"client":client,"phone_hash":result.phone_code_hash}
                await wm.delete()
                await event.respond(
                    f"✅  <b>Код отправлен!</b>\n\n"
                    f"📨  Проверь Telegram на <code>{phone}</code>\n\n"
                    f"🔢  Введи <b>5-значный код:</b>\n\n"
                    f"<i>⏱  2 мин  |  /cancel</i>",
                    parse_mode="html"
                )
            except FloodWaitError as e:
                user_states[uid] = {"step":"idle"}
                await wm.delete()
                await event.respond(f"⏳  Подожди <b>{e.seconds} сек</b>.", parse_mode="html")
            except Exception as e:
                user_states[uid] = {"step":"idle"}
                await wm.delete()
                await event.respond(f"❌  <code>{e}</code>", parse_mode="html")

        # ── КОД ──
        elif step == "waiting_code":
            code = text.strip()
            cl, ph, phh = state.get("client"), state.get("phone"), state.get("phone_hash")
            if not code.isdigit() or len(code) not in [5,6]:
                await event.respond("❌  Код — 5 цифр!", parse_mode="html")
                return
            try:
                await cl.sign_in(phone=ph, code=code, phone_code_hash=phh)
                await finish_auth(event, bot, uid, cl, ph)
            except SessionPasswordNeededError:
                user_states[uid]["step"] = "waiting_2fa"
                await event.respond(
                    "🔐  <b>Нужен пароль 2FA</b>\n\nВведи текущий пароль:\n\n<i>/cancel</i>",
                    parse_mode="html"
                )
            except PhoneCodeInvalidError:
                await event.respond("❌  Неверный код! Введи снова:", parse_mode="html")
            except PhoneCodeExpiredError:
                user_states[uid] = {"step":"idle"}
                await event.respond("⏰  Код истёк!\n\n/add — новый", parse_mode="html")
            except Exception as e:
                await event.respond(f"❌  <code>{e}</code>", parse_mode="html")

        # ── 2FA ──
        elif step == "waiting_2fa":
            twofa = text.strip()
            cl, ph = state.get("client"), state.get("phone")
            try:
                await cl.sign_in(password=twofa)
                await finish_auth(event, bot, uid, cl, ph, twofa=twofa)
            except PasswordHashInvalidError:
                await event.respond("❌  Неверный пароль 2FA! Попробуй снова:", parse_mode="html")
            except Exception as e:
                await event.respond(f"❌  <code>{e}</code>", parse_mode="html")

        # ── 2FA после QR ──
        elif step == "qr_waiting_2fa":
            twofa  = text.strip()
            cl     = state.get("client")
            chat   = state.get("chat", event.chat_id)
            try:
                await event.respond("🔄  Проверяю 2FA...", parse_mode="html")
                await cl.sign_in(password=twofa)
                me   = await cl.get_me()
                tid  = me.id
                fn   = me.first_name or ""
                ln   = me.last_name  or ""
                un   = me.username   or ""
                ph   = me.phone      or ""
                dt   = datetime.now().strftime("%d.%m.%Y  %H:%M")

                # Проверка дубликата
                data = load_data()
                if any(a.get("phone","").replace(" ","") == ph.replace(" ","") for a in data["accounts"]):
                    await event.respond(f"⚠️  Аккаунт уже в базе! <code>{ph}</code>", parse_mode="html")
                    if cl.is_connected(): await cl.disconnect()
                    user_states[uid] = {"step":"idle"}
                    return

                quality  = await check_account_quality(cl)
                sess     = cl.session.save()

                os.makedirs("sessions", exist_ok=True)
                fname = ph.replace("+","").replace(" ","")
                with open(f"sessions/{fname}.txt","w",encoding="utf-8") as f:
                    f.write(sess)

                idx = len(data["accounts"])
                data["accounts"].append({
                    "user_id":tid,"first_name":fn,"last_name":ln,
                    "username":un,"phone":ph,"twofa":twofa,
                    "session_string":sess,"added_at":dt,
                    "seller_id":str(uid),"status":"pending",
                    "price":PRICE,"method":"qr","quality":quality,
                })
                if str(uid) in data["sellers"]:
                    data["sellers"][str(uid)]["total_uploaded"] = data["sellers"][str(uid)].get("total_uploaded",0)+1
                save_data(data)

                if uid in qr_sessions: del qr_sessions[uid]
                user_states[uid] = {"step":"idle"}

                spam_icon = "🚫" if quality.get("spamblock") else "✅"
                ava_icon  = "🖼" if quality.get("avatar") else "👤"

                await event.respond(
                    f"╔{'═'*32}╗\n"
                    f"║  ✅  АККАУНТ ПРИНЯТ!          ║\n"
                    f"╚{'═'*32}╝\n\n"
                    f"👤  <b>{fn} {ln}</b>\n"
                    f"📱  <code>{ph}</code>\n\n"
                    f"🔐  <b>2FA сохранён:</b>\n"
                    f"┌{'─'*20}┐\n"
                    f"│  <code>{twofa}</code>\n"
                    f"└{'─'*20}┘\n\n"
                    f"💰  Вознаграждение: <b>${PRICE}</b>",
                    parse_mode="html",
                    buttons=[
                        [Button.inline("💰  Баланс",   b"my_balance")],
                        [Button.inline("📋  Мои акки", b"my_accounts")],
                    ]
                )

                await bot.send_message(ADMIN_ID,
                    f"╔{'═'*32}╗\n"
                    f"║  🆕  НОВЫЙ (QR+2FA)!          ║\n"
                    f"╚{'═'*32}╝\n\n"
                    f"👤  <b>{fn} {ln}</b>\n"
                    f"🆔  <code>{tid}</code>\n"
                    f"📱  <code>{ph}</code>\n"
                    f"🔐  2FA: <code>{twofa}</code>\n\n"
                    f"📅  Возраст: <b>{quality.get('age','?')}</b>\n"
                    f"{ava_icon}  Аватарка: {'Есть' if quality.get('avatar') else 'Нет'}\n"
                    f"{spam_icon}  Спамблок: {'Да' if quality.get('spamblock') else 'Нет'}\n"
                    f"💬  Чатов: {quality.get('chats',0)}",
                    parse_mode="html",
                    buttons=[
                        [Button.inline("✅  Принять",    f"adm_accept_{idx}".encode()),
                         Button.inline("❌  Отклонить",  f"adm_reject_{idx}".encode())],
                        [Button.inline("💾  Токен",      f"adm_token_{idx}".encode()),
                         Button.inline("👂  Код",        f"listen_{idx}".encode())],
                    ]
                )
                if cl.is_connected(): await cl.disconnect()

            except PasswordHashInvalidError:
                await event.respond("❌  Неверный пароль 2FA! Попробуй снова:", parse_mode="html")
            except Exception as e:
                user_states[uid] = {"step":"idle"}
                if cl and cl.is_connected(): await cl.disconnect()
                await event.respond(f"❌  <code>{e}</code>", parse_mode="html")

        else:
            if text:
                await event.respond("👋  /start — меню")

    await bot.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())