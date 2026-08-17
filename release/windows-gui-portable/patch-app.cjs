const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

function replaceExactlyOnce(text, before, after, label) {
  const first = text.indexOf(before);
  if (first === -1 || text.indexOf(before, first + before.length) !== -1) {
    throw new Error(`expected exactly one ${label} block`);
  }
  return text.slice(0, first) + after + text.slice(first + before.length);
}

function asarHeaderHash(asarPath) {
  const archive = fs.readFileSync(asarPath);
  if (archive.length < 16) {
    throw new Error("app.asar is too small");
  }
  const headerPickleSize = archive.readUInt32LE(4);
  const headerStart = 8;
  const headerEnd = headerStart + headerPickleSize;
  if (headerEnd > archive.length || headerPickleSize < 8) {
    throw new Error("invalid app.asar header size");
  }
  const stringLength = archive.readUInt32LE(headerStart + 4);
  const stringStart = headerStart + 8;
  const stringEnd = stringStart + stringLength;
  if (stringEnd > headerEnd) {
    throw new Error("invalid app.asar header string length");
  }
  return crypto.createHash("sha256").update(archive.subarray(stringStart, stringEnd)).digest("hex");
}

const [command, targetPath, extraPath] = process.argv.slice(2);

if (command === "patch-source") {
  const indexPath = path.join(targetPath, "out", "main", "index.js");
  let source = fs.readFileSync(indexPath, "utf8");

  source = replaceExactlyOnce(
    source,
    `configureApplicationPaths(developmentSwitchValue("user-data"));`,
    `configureApplicationPaths(process.env.SING_BOX_PORTABLE_USER_DATA || developmentSwitchValue("user-data"));`,
    "portable user-data",
  );

  source = replaceExactlyOnce(
    source,
    `if (developmentUserDataPath !== "") {\n    paths = {\n      userData: developmentUserDataPath,\n      daemonData: process.platform === "win32" ? "C:\\\\ProgramData\\\\sing-box-daemon" : "/var/lib/sing-box-daemon"\n    };`,
    `if (developmentUserDataPath !== "") {\n    paths = {\n      userData: developmentUserDataPath,\n      daemonData: process.env.SING_BOX_PORTABLE_DAEMON_DATA || (process.platform === "win32" ? "C:\\\\ProgramData\\\\sing-box-daemon" : "/var/lib/sing-box-daemon")\n    };`,
    "portable daemon-data",
  );

  source = replaceExactlyOnce(
    source,
    `if (process.platform === "win32" && app.isPackaged) {\n  daemonTransport = daemonWorkerTransport;\n} else {`,
    `if (process.platform === "win32" && app.isPackaged && process.env.SING_BOX_PORTABLE_DAEMON_URL) {\n  daemonTransport = createGrpcTransport({\n    baseUrl: process.env.SING_BOX_PORTABLE_DAEMON_URL,\n    interceptors: [localeInterceptor]\n  });\n} else if (process.platform === "win32" && app.isPackaged) {\n  daemonTransport = daemonWorkerTransport;\n} else {`,
    "portable daemon transport",
  );

  source = replaceExactlyOnce(
    source,
    `async function startServiceWithContent(content) {\n  if (desktopService === null) {\n    throw new Error("daemon is not available");\n  }`,
    `async function startServiceWithContent(content) {\n  if (/"type"\\s*:\\s*"tun"/i.test(content)) {\n    throw new Error("TUN is disabled in this portable no-admin build. Use a mixed inbound and system proxy instead.");\n  }\n  if (desktopService === null) {\n    throw new Error("daemon is not available");\n  }`,
    "TUN guard",
  );

  fs.writeFileSync(indexPath, source, "utf8");
  process.stdout.write(`Patched ${indexPath}\n`);
} else if (command === "patch-integrity") {
  const executablePath = targetPath;
  const oldAsarPath = extraPath;
  const newAsarPath = process.argv[5];
  if (!newAsarPath) {
    throw new Error("missing new app.asar path");
  }
  const oldHash = asarHeaderHash(oldAsarPath);
  const newHash = asarHeaderHash(newAsarPath);
  const executable = fs.readFileSync(executablePath);
  const oldHashBuffer = Buffer.from(oldHash, "ascii");
  const position = executable.indexOf(oldHashBuffer);
  if (position === -1 || executable.lastIndexOf(oldHashBuffer) !== position) {
    throw new Error("executable does not contain exactly one original app.asar integrity hash");
  }
  Buffer.from(newHash, "ascii").copy(executable, position);
  fs.writeFileSync(executablePath, executable);
  process.stdout.write(`Updated embedded ASAR hash ${oldHash} -> ${newHash}\n`);
} else if (command === "header-hash") {
  process.stdout.write(`${asarHeaderHash(targetPath)}\n`);
} else {
  throw new Error("usage: patch-app.cjs patch-source <unpacked-dir> | patch-integrity <exe> <old-asar> <new-asar> | header-hash <asar>");
}
