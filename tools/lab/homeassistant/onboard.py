"""Finishes the first-run setup of the lab's Home Assistant and prints a long-lived token.

Run by ../homeassistant.sh with Home Assistant's own Python (it needs aiohttp).
Creates the owner account "lab" (password "lab-lab-lab"): a throw-away instance on this Mac.
"""
import argparse
import asyncio
import json
import pathlib

import aiohttp


async def main(url: str, out: pathlib.Path) -> None:
    client_id = f"{url}/"
    async with aiohttp.ClientSession() as http:
        async with http.get(f"{url}/api/onboarding") as r:
            steps = {s["step"]: s["done"] for s in await r.json()}
        if steps.get("user"):
            if out.exists():
                print(out.read_text().strip())
                return
            raise SystemExit("Already set up by someone else: delete the lab's .ha/config folder to start over.")

        async with http.post(f"{url}/api/onboarding/users", json={
            "client_id": client_id, "name": "Lab", "username": "lab", "password": "lab-lab-lab", "language": "en",
        }) as r:
            code = (await r.json())["auth_code"]
        async with http.post(f"{url}/auth/token", data={
            "grant_type": "authorization_code", "code": code, "client_id": client_id,
        }) as r:
            access = (await r.json())["access_token"]
        auth = {"Authorization": f"Bearer {access}"}
        for step, body in (("core_config", {}), ("analytics", {}),
                           ("integration", {"client_id": client_id, "redirect_uri": f"{url}/?auth_callback=1"})):
            async with http.post(f"{url}/api/onboarding/{step}", json=body, headers=auth) as r:
                r.raise_for_status()

        async with http.ws_connect(f"{url}/api/websocket") as ws:
            await ws.receive_json()  # auth_required
            await ws.send_json({"type": "auth", "access_token": access})
            await ws.receive_json()  # auth_ok
            await ws.send_json({"id": 1, "type": "auth/long_lived_access_token",
                                "client_name": "House Control lab", "lifespan": 3650})
            token = (await ws.receive_json())["result"]

    out.write_text(token + "\n")
    out.chmod(0o600)
    print(token)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8123")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    asyncio.run(main(args.url.rstrip("/"), args.out))
