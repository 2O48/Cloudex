export const API_PREFIX = "/api";

export const ENDPOINTS = {
  health: `${API_PREFIX}/health`,
  models: `${API_PREFIX}/models`,
  projects: `${API_PREFIX}/projects`,
  threads: `${API_PREFIX}/threads`,
  events: `${API_PREFIX}/events`,
  files: `${API_PREFIX}/files`,
};

export function threadEndpoint(threadId, action = "") {
  const encodedId = encodeURIComponent(threadId);
  return `${ENDPOINTS.threads}/${encodedId}${action ? `/${action}` : ""}`;
}

export function threadStreamEndpoint(threadId) {
  return `${threadEndpoint(threadId)}/stream`;
}

export function withQuery(endpoint, params = {}) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") search.set(key, String(value));
  }
  const query = search.toString();
  return query ? `${endpoint}?${query}` : endpoint;
}
