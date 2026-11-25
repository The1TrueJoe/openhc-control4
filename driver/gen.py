#!/usr/bin/env python3
"""Generate one Control4 driver per openHC model from a single table.

Each openHC controller model gets its own .c4z with its exact, STATIC AV + IO
and its own SDDP type (openhc:<slug>) — because Control4 audio/video bindings
cannot be added dynamically, so a per-model split is the only way to declare the
real AV. The IO is static too (user decision): no C4:AddDynamicBinding.

Run via package.sh. For each model it writes build/<slug>/{driver.xml,
driver.lua, www} and zips openhc-<slug>.c4z. The same per-model IO counts are
baked into driver.lua as OHC_IO_GEOM, so driver.xml and io.lua never disagree.

IO counts: ea1/ea3/hc800/ca1/iox from openHC board.env (ea3 cross-checked
against the live box's /api/io); ea5/hc250 confirmed by the user. AV from
Control4 datasheets.
"""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

# kind -> (Control4 class, connection-name). IO is 1-based (iod's numbering).
IO_CLASS = {"serial": ("RS_232", "Serial"), "ir": ("IR_OUT", "IR Output"),
            "relay": ("RELAY", "Relay"), "contact": ("CONTACT_SENSOR", "Contact")}

# Per model:
#   nav   : on-screen navigator (uidevice + onscreen + HDMI video). openHC needs
#           wpe for this — only the EA family and HC-800 have it.
#   io    : {serial, ir, relay, contact} static counts.
#   hdmi  : the HDMI A/V output (the navigator's video).
#   video : extra video outputs beyond HDMI (component on HC-250/HC-800).
#   audio : Control4's own driver for this model, which child.lua adds as the
#           box's audio device (Director streams only to Control4's drivers).
MODELS = {
    "ea1": dict(name="openHC EA1", nav=True, io=dict(serial=2, ir=4, relay=0, contact=0), hdmi=True, video=[], audio="control4_ea1.c4i"),
    "ea3": dict(name="openHC EA3", nav=True, io=dict(serial=3, ir=6, relay=1, contact=1), hdmi=True, video=[], audio="control4_ea3.c4i"),
    "ea5": dict(name="openHC EA5", nav=True, io=dict(serial=3, ir=6, relay=1, contact=1), hdmi=True, video=[], audio="control4_ea5.c4i"),
    "hc250": dict(name="openHC HC250", nav=False, io=dict(serial=1, ir=4, relay=1, contact=1), hdmi=True, video=["Component"], audio="control4_tr1.c4i"),
    "hc800": dict(name="openHC HC800", nav=True, io=dict(serial=2, ir=6, relay=4, contact=4), hdmi=True, video=["Component"], audio="control4_hc800.c4i"),
    "ca1": dict(name="openHC CA1", nav=False, io=dict(serial=1, ir=0, relay=0, contact=0), hdmi=False, video=[], audio=None),
    "iox": dict(name="openHC IOX", nav=False, io=dict(serial=4, ir=8, relay=8, contact=8), hdmi=False, video=[], audio=None),
}



def conn(cid, name, ctype, consumer, asrc, vsrc, line, classes, proxy=None, hidden=False, autobind=False,
         extra=None):
    pb = f' proxybindingid="{proxy}"' if proxy else ""
    cls = "".join(f"<class>{'<autobind>True</autobind>' if autobind else ''}"
                  f"<classname>{c}</classname></class>" for c in classes)
    h = "<hidden>True</hidden>" if hidden else ""
    x = f"<ExtraInfo>{extra}</ExtraInfo>" if extra is not None else ""
    return (f'    <connection{pb}><id>{cid}</id><facing>6</facing>'
            f'<connectionname>{name}</connectionname><type>{ctype}</type>'
            f'<consumer>{consumer}</consumer><audiosource>{asrc}</audiosource>'
            f'<videosource>{vsrc}</videosource><linelevel>{line}</linelevel>'
            f'{x}<classes>{cls}</classes>{h}</connection>')


def audio_classes(label):
    """Stock controller classes: coax is DIGITAL_COAX, everything else STEREO."""
    return ["DIGITAL_COAX"] if "Coax" in label else ["STEREO"]


def connections(m):
    out, io = [], m["io"]
    # Primary control proxy (every model), + uidevice on nav models.
    out.append(conn(5001, "Controller", 2, "False", "False", "False", "False", ["CONTROLLER"], hidden=True))
    if m["nav"]:
        out.append(conn(5002, "UI Device", 2, "False", "False", "False", "False", ["UI_DEVICE"], hidden=True))
    # The audio outputs belong to the audio child (Control4's own driver, see
    # child.lua). HDMI stays here too: it carries the on-screen navigator's video.
    if m["hdmi"]:
        out.append(conn(4072, "HDMI (Audio/Video)", 6, "False", "True", "True", "True", ["HDMI"], proxy=5001))
    for i, label in enumerate(m["video"]):
        out.append(conn(4200 + i, f"{label} Video", 6, "False", "False", "True", "False",
                        [label.upper()], proxy=5001))
    if m["nav"]:
        out.append(conn(7500, "Onscreen Navigator", 7, "False", "False", "False", "False",
                        ["ONSCREEN_SELECTION"], proxy=5001))
    # The box address (SDDP fills it) + MQTT/navigator ports.
    ports = '<port><name>Navigator</name><number>9010</number></port>' if m["nav"] else ""
    out.append(f'    <connection><id>6001</id><facing>6</facing><connectionname>{m["name"]}</connectionname>'
               f'<type>4</type><consumer>True</consumer><audiosource>False</audiosource>'
               f'<videosource>False</videosource><linelevel>True</linelevel>'
               f'<classes><class><classname>TCP</classname><ports>{ports}</ports></class></classes></connection>')
    # Static IO (iod numbers from 1): serial 1-4, IR 11-18, relay 21-24, contact 31-34.
    for kind, base in (("serial", 1), ("ir", 11), ("relay", 21), ("contact", 31)):
        cls, nm = IO_CLASS[kind]
        for i in range(io.get(kind, 0)):
            out.append(conn(base + i, f"{nm} {i + 1}", 1, "False", "False", "False", "False", [cls]))
    return "\n".join(out)


def driver_xml(slug, m):
    caps = []
    proxies = '    <proxy proxybindingid="5001" primary="True" name="%s">controller</proxy>' % m["name"]
    if m["nav"]:
        caps += ["<has_video_output>true</has_video_output>", "<has_ui_device>true</has_ui_device>",
                 "<has_navigator>true</has_navigator>",
                 '<auto_bind_onscreen_selection proxybindingid="5001">true</auto_bind_onscreen_selection>']
        proxies += '\n    <proxy proxybindingid="5002">uidevice</proxy>'
    caps = ("  <capabilities>\n" + "".join(f"    {c}\n" for c in caps) + "  </capabilities>\n\n") if caps else ""
    props = """    <properties>
      <property><name>openHC Web UI</name><type>LINK</type><default></default>
        <tooltip>The box's own dashboard (:80). Filled in once the box address resolves.</tooltip></property>
      <property><name>Target IP Address</name><type>STRING</type><default></default>
        <tooltip>The openHC controller. Filled in from the Network connection; set it here only without one.</tooltip></property>
      <property><name>Target Port</name><type>RANGED_INTEGER</type><minimum>1</minimum><maximum>65535</maximum><default>9010</default>
        <tooltip>The on-screen navigator's sink on the openHC controller.</tooltip></property>
      <property><name>Send Project Token</name><type>LIST</type><items><item>Yes</item><item>No</item></items><default>Yes</default>
        <tooltip>Mint a Director REST token and send it to the openHC controller, so its on-screen UI shows this project.</tooltip></property>
      <property><name>Token Status</name><type>STRING</type><readonly>true</readonly><default></default></property>
      <property><name>Link Status</name><type>STRING</type><readonly>true</readonly><default>disconnected</default></property>
      <property><name>Last Command</name><type>STRING</type><readonly>true</readonly><default></default></property>
      <property><name>IO Port</name><type>RANGED_INTEGER</type><minimum>1</minimum><maximum>65535</maximum><default>1883</default>
        <tooltip>iod's MQTT port on the openHC controller.</tooltip></property>
      <property><name>IO Token</name><type>STRING</type><password>true</password><default></default>
        <tooltip>iod's IOD_TOKEN, if the box sets one.</tooltip></property>
      <property><name>Topic Prefix</name><type>STRING</type><default>openhc</default></property>
      <property><name>IO Status</name><type>STRING</type><readonly>true</readonly><default>disconnected</default></property>
      <property><name>Audio Device</name><type>STRING</type><readonly>true</readonly><default></default>
        <tooltip>The box's audio device: Control4's own driver for this model, added and pointed at the box by this driver.</tooltip></property>
      <property><name>Last IO Command</name><type>STRING</type><readonly>true</readonly><default></default>
        <tooltip>The last command Director sent an IO connection, with its parameters.</tooltip></property>
    </properties>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<devicedata>
  <copyright>Copyright 2026 Joseph Telaak</copyright>
  <creator>Joseph Telaak</creator>
  <name>{m['name']}</name>
  <manufacturer>openHC</manufacturer>
  <model>openhc-{slug}</model>
  <created>2026-11-17</created>
  <modified>2026-11-18</modified>
  <version>{os.environ.get('OHC_VERSION', '1')}</version>
  <control>lua_gen</control>
  <controlmethod>ip</controlmethod>
  <driver>DriverWorks</driver>
  <documentation file="www/documentation.html"/>
  <!-- c4sddp on the box announces this Type, so Composer pairs the discovered
       box with this driver and fills in the Network connection (6001). -->
  <search_types>
    <type>openhc:{slug}</type>
  </search_types>
  <composer_categories>
    <category>Controllers</category>
  </composer_categories>

{caps}  <proxies>
{proxies}
  </proxies>

  <connections>
{connections(m)}
  </connections>

  <config>
    <script file="driver.lua" jit="1"/>
{props}
    <tabs>
      <tab name="openHC Setup" file="setup.html"/>
      <tab name="openHC Docs" file="documentation.html"/>
    </tabs>
    <actions><action><name>Send Test Line</name><command>TEST_LINK</command></action></actions>
  </config>
</devicedata>
"""


def prelude(m):
    io = m["io"]
    return ("-- Generated per-model geometry (gen.py). Static: no dynamic bindings.\n"
            "OHC_IO_GEOM = { serial = %d, ir = %d, relay = %d, contact = %d }\n"
            "OHC_AUDIO_C4I = %s\n\n" % (io["serial"], io["ir"], io["relay"], io["contact"],
                                         '"%s"' % m["audio"] if m["audio"] else "nil"))


def main():
    nav = os.path.join(HERE, "../navigator/lib/driver/driver.lua")
    mqtt = os.path.join(HERE, "control4-lua-mqtt/mqtt.lua")
    for f in (nav, mqtt):
        if not os.path.exists(f):
            sys.exit(f"submodule missing ({f}): git submodule update --init --recursive")
    build = os.path.join(HERE, "build")
    shutil.rmtree(build, ignore_errors=True)
    nav_lua, mqtt_lua = open(nav).read(), open(mqtt).read()
    io_lua, child_lua = open(os.path.join(HERE, "io.lua")).read(), open(os.path.join(HERE, "child.lua")).read()
    zigbee_lua = open(os.path.join(HERE, "zigbee.lua")).read()
    for slug, m in MODELS.items():
        d = os.path.join(build, slug)
        os.makedirs(os.path.join(d, "www"))
        open(os.path.join(d, "driver.xml"), "w").write(driver_xml(slug, m))
        # control4-lua-mqtt (global C4MQTT) must precede io.lua; prelude first.
        # zigbee.lua wraps ExecuteCommand + OHC_STATE, so it comes last.
        open(os.path.join(d, "driver.lua"), "w").write(
            prelude(m) + nav_lua + mqtt_lua + io_lua + child_lua + zigbee_lua)
        for n in os.listdir(os.path.join(HERE, "www")):
            shutil.copy(os.path.join(HERE, "www", n), os.path.join(d, "www", n))
        out = os.path.join(HERE, f"openhc-{slug}.c4z")
        if os.path.exists(out):
            os.remove(out)
        subprocess.run(["zip", "-r", "-X", out, "driver.xml", "driver.lua", "www"], cwd=d, check=True,
                       stdout=subprocess.DEVNULL)
        print(f"built openhc-{slug}.c4z  (serial {m['io']['serial']} ir {m['io']['ir']} "
              f"relay {m['io']['relay']} contact {m['io']['contact']}, audio {m['audio'] or 'none'})")


if __name__ == "__main__":
    main()
