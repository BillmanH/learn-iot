import urllib.request, hashlib, base64, datetime, os, re

url = "http://10.0.0.48:2020/onvif/device_service"
username = "homecamnet"
password = "40z$jiOdg6"

def onvif_auth_test(user, pw):
    nonce_bytes = os.urandom(20)
    nonce_b64 = base64.b64encode(nonce_bytes).decode()
    created = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    digest_raw = nonce_bytes + created.encode("utf-8") + pw.encode("utf-8")
    digest = base64.b64encode(hashlib.sha1(digest_raw).digest()).decode()
    soap = f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
  <s:Header><wsse:Security><wsse:UsernameToken>
    <wsse:Username>{user}</wsse:Username>
    <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</wsse:Password>
    <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{nonce_b64}</wsse:Nonce>
    <wsu:Created>{created}</wsu:Created>
  </wsse:UsernameToken></wsse:Security></s:Header>
  <s:Body><GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body>
</s:Envelope>"""
    req = urllib.request.Request(url, soap.encode(), {"Content-Type": "application/soap+xml; charset=utf-8", "SOAPAction": ""})
    try:
        resp = urllib.request.urlopen(req, timeout=5)
        return "SUCCESS: " + resp.read().decode()[:400]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        fault = re.search(r'<.*?:Value[^>]*>([^<]+)<', body)
        subcode = re.search(r'<.*?:Value[^>]*>(ter:[^<]+)<', body)
        return f"FAIL HTTP {e.code}: subcode={subcode.group(1) if subcode else '?'} value={fault.group(1) if fault else '?'} | body={body[:300]}"
    except Exception as e:
        return f"ERROR: {e}"

# --- tests ---

def onvif_text_test(user, pw):
    """Test with PasswordText instead of PasswordDigest"""
    import datetime
    soap = f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
  <s:Header><wsse:Security><wsse:UsernameToken>
    <wsse:Username>{user}</wsse:Username>
    <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText">{pw}</wsse:Password>
  </wsse:UsernameToken></wsse:Security></s:Header>
  <s:Body><GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body>
</s:Envelope>"""
    req = urllib.request.Request(url, soap.encode(), {"Content-Type": "application/soap+xml; charset=utf-8", "SOAPAction": ""})
    try:
        resp = urllib.request.urlopen(req, timeout=5)
        return "SUCCESS: " + resp.read().decode()[:200]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        subcode = re.search(r'<.*?:Value[^>]*>(ter:[^<]+)<', body)
        return f"FAIL HTTP {e.code}: {subcode.group(1) if subcode else '?'}"
    except Exception as e:
        return f"ERROR: {e}"

def onvif_clock_check():
    """Check camera system time vs local time — reveals clock skew for WS-Security"""
    soap = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body><GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body>
</s:Envelope>"""
    req = urllib.request.Request(url, soap.encode(),
        {"Content-Type": "application/soap+xml; charset=utf-8", "SOAPAction": ""})
    before = datetime.datetime.utcnow()
    try:
        resp = urllib.request.urlopen(req, timeout=5)
        body = resp.read().decode()
        after = datetime.datetime.utcnow()
        import re
        Y  = re.search(r'<tt:Year>(\d+)', body)
        Mo = re.search(r'<tt:Month>(\d+)', body)
        D  = re.search(r'<tt:Day>(\d+)', body)
        H  = re.search(r'<tt:Hour>(\d+)', body)
        Mi = re.search(r'<tt:Minute>(\d+)', body)
        S  = re.search(r'<tt:Second>(\d+)', body)
        if all([Y, Mo, D, H, Mi, S]):
            cam_dt = datetime.datetime(int(Y.group(1)), int(Mo.group(1)), int(D.group(1)),
                                        int(H.group(1)), int(Mi.group(1)), int(S.group(1)))
            nuc_dt = before + (after - before) / 2
            skew_s = (nuc_dt - cam_dt).total_seconds()
            ok = "OK" if abs(skew_s) < 300 else "WARNING: >300s LIMIT!"
            return f"Camera={cam_dt.strftime('%Y-%m-%dT%H:%M:%SZ')}  NUC={nuc_dt.strftime('%Y-%m-%dT%H:%M:%S')}Z  skew={skew_s:+.1f}s  [{ok}]"
        return f"Could not parse time. Raw: {body[:300]}"
    except Exception as e:
        return f"ERROR: {e}"


print("=== Clock skew check ===")
print(" ", onvif_clock_check())
print()

print("=== PasswordDigest tests ===")
for user, pw in [
    ("homecamnet", "40z$jiOdg6"),
    ("Homecamnet", "40z$jiOdg6"),
]:
    print(f"  Digest user='{user}': ", end="")
    print(onvif_auth_test(user, pw))

print("\n=== PasswordText tests ===")
for user, pw in [
    ("homecamnet", "40z$jiOdg6"),
    ("Homecamnet", "40z$jiOdg6"),
]:
    print(f"  Text   user='{user}': ", end="")
    print(onvif_text_test(user, pw))
