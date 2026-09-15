import json, sys, shutil, uuid, os, datetime
src, dst_root, name = sys.argv[1], sys.argv[2], sys.argv[3]
new_id = str(uuid.uuid4()).upper()
dst = os.path.join(dst_root, new_id)
shutil.copytree(src, dst)
p = os.path.join(dst, "project.json")
d = json.load(open(p))
c = d["capture"]
c["id"] = new_id; c["originID"] = new_id
c.pop("importedFromID", None); c.pop("derivedFromOriginID", None)
c["name"] = name
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
c["modifiedAt"] = now
for b in d.get("blends", []): b["captureID"] = new_id
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print(new_id)
