import path from "node:path";

export function isPathInside(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === ""
    || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

export function normalizeAllowedPath(candidate, { defaultPath, roots }) {
  const resolved = path.resolve(candidate || defaultPath);
  if (!roots.some((root) => isPathInside(root, resolved))) {
    const error = new Error("Path is outside allowed file roots");
    error.status = 403;
    throw error;
  }
  return resolved;
}
