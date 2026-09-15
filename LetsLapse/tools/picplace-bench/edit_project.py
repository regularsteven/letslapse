import json, sys, datetime
p, name = sys.argv[1], sys.argv[2]
d = json.load(open(p)); c = d["capture"]
c["name"] = name
c["modifiedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print("edited:", name, c["modifiedAt"])
