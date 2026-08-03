import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Constants from "expo-constants";
import { registerRootComponent } from "expo";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Linking,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { ENDPOINTS, threadEndpoint, threadStreamEndpoint } from "@cloudex/shared";

const expoHost = Constants.expoConfig?.hostUri?.split(":")[0];
const defaultServerUrl = expoHost ? `http://${expoHost}:8787` : "http://127.0.0.1:8787";
const defaultAuthToken = process.env.EXPO_PUBLIC_CLOUDEX_AUTH_TOKEN || "";

function withToken(url, token) {
  if (!token) return url;
  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}token=${encodeURIComponent(token)}`;
}

function normalizeText(value) {
  if (Array.isArray(value)) return value.join("\n");
  if (value && typeof value === "object") return JSON.stringify(value);
  return value || "";
}

function itemText(item) {
  if (item.type === "agentMessage") return item.text || "";
  if (item.type === "userMessage") {
    return (item.content || []).map((content) => content.text || content.value || "").join("").trim();
  }
  if (item.type === "reasoning") return normalizeText(item.summary || item.text);
  return normalizeText(item.text || item.command);
}

function errorCodeText(error) {
  return error?.codexErrorInfo || error?.codex_error_info || error?.code || error?.type || "";
}

function turnErrorText(turn) {
  if (!turn?.error) return "";
  const message = turn.error.message || normalizeText(turn.error);
  const code = errorCodeText(turn.error);
  return [message, code ? `错误代码：${code}` : ""].filter(Boolean).join("\n");
}

function notificationErrorText(notification) {
  const params = notification?.params || {};
  return turnErrorText(params.turn) || turnErrorText(params) || normalizeText(params.error?.message || params.error || "");
}

function latestTurnErrorText(turns = []) {
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const text = turnErrorText(turns[index]);
    if (text) return text;
  }
  return "";
}

function conversationFromTurns(turns = []) {
  return turns.flatMap((turn) => {
    const messages = (turn.items || [])
    .filter((item) => item.type === "userMessage" || item.type === "agentMessage")
    .map((item) => ({
      id: item.id || `${turn.id}-${item.type}`,
      role: item.type === "userMessage" ? "user" : item.type === "agentMessage" ? "assistant" : "system",
      text: itemText(item),
    }))
    .filter((item) => item.text);
    const errorText = turnErrorText(turn);
    if (errorText) {
      messages.push({
        id: `${turn.id}-error`,
        role: "error",
        text: errorText,
      });
    }
    return messages;
  });
}

function trimTrailingAssistantMessage(conversation = []) {
  const lastAssistantIndex = conversation.map((item) => item.role).lastIndexOf("assistant");
  if (lastAssistantIndex === -1) return conversation;
  return conversation.filter((_, index) => index !== lastAssistantIndex);
}

function formatLiveText(value = "") {
  return value
    .replace(/\r\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/([^\n])(\n[-*•]\s)/g, "$1\n$2")
    .replace(/([^\n])(\n\d+[.)、]\s)/g, "$1\n$2")
    .trimStart();
}

function statusText(thread) {
  const type = thread?.status?.type;
  const flags = thread?.status?.activeFlags || [];
  if (type === "active" && flags.includes("waitingOnApproval")) return "等待审批";
  if (type === "active") return "运行中";
  if (type === "idle") return "已完成";
  if (type === "notLoaded") return "未加载";
  return type || "未知状态";
}

function notificationThreadId(notification) {
  const params = notification?.params || {};
  return params.threadId || params.thread?.id || params.turn?.threadId || null;
}

function formatDate(timestamp) {
  if (!timestamp) return "";
  return new Date(timestamp * 1000).toLocaleString();
}

function parseSseEvent(raw) {
  const result = { data: [], event: "message", id: null };
  for (const line of raw.replace(/\r/g, "").split("\n")) {
    if (!line || line.startsWith(":")) continue;
    const separator = line.indexOf(":");
    const key = separator === -1 ? line : line.slice(0, separator);
    const value = (separator === -1 ? "" : line.slice(separator + 1)).replace(/^ /, "");
    if (key === "event") result.event = value;
    if (key === "id") result.id = value;
    if (key === "data") result.data.push(value);
  }
  return { ...result, data: result.data.join("\n") };
}

// React Native does not provide a built-in EventSource. XMLHttpRequest streams
// responseText incrementally on iOS and Android, which is sufficient for SSE.
function openSse(url, token, handlers) {
  const request = new XMLHttpRequest();
  let consumed = 0;
  let pending = "";
  let intentional = false;
  let disconnected = false;
  const notifyDisconnect = (error) => {
    if (intentional || disconnected) return;
    disconnected = true;
    handlers.onDisconnect?.(error);
  };
  const drain = () => {
    const response = request.responseText || "";
    pending += response.slice(consumed);
    consumed = response.length;
    let boundary;
    while ((boundary = pending.indexOf("\n\n")) !== -1) {
      const parsed = parseSseEvent(pending.slice(0, boundary));
      pending = pending.slice(boundary + 2);
      if (parsed.data) handlers.onEvent?.(parsed);
    }
  };
  request.open("GET", withToken(url, token));
  if (token) request.setRequestHeader("Authorization", `Bearer ${token}`);
  request.setRequestHeader("Accept", "text/event-stream");
  request.onreadystatechange = () => {
    if (request.readyState === 2 && request.status >= 200 && request.status < 300) handlers.onOpen?.();
    if (request.readyState === 4) {
      drain();
      notifyDisconnect(new Error(request.status ? `实时连接已关闭 (${request.status})` : "实时连接已关闭"));
    }
  };
  request.onprogress = drain;
  request.onerror = () => notifyDisconnect(new Error("实时连接失败"));
  request.send();
  return () => {
    intentional = true;
    request.abort();
  };
}

export default function App() {
  const [serverUrl, setServerUrl] = useState(defaultServerUrl);
  const [authToken, setAuthToken] = useState(defaultAuthToken);
  const [draftServerUrl, setDraftServerUrl] = useState(defaultServerUrl);
  const [draftAuthToken, setDraftAuthToken] = useState(defaultAuthToken);
  const [models, setModels] = useState([]);
  const [selectedModel, setSelectedModel] = useState("");
  const [draftSelectedModel, setDraftSelectedModel] = useState("");
  const [projects, setProjects] = useState([]);
  const [threads, setThreads] = useState([]);
  const [selectedProjectCwd, setSelectedProjectCwd] = useState(null);
  const [selectedThreadId, setSelectedThreadId] = useState(null);
  const [detail, setDetail] = useState(null);
  const [message, setMessage] = useState("");
  const [status, setStatus] = useState("未连接");
  const [busy, setBusy] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [creatingNew, setCreatingNew] = useState(false);
  const [connectionVersion, setConnectionVersion] = useState(0);
  const [liveDelta, setLiveDelta] = useState("");
  const [liveRunning, setLiveRunning] = useState(false);
  const [localNotices, setLocalNotices] = useState([]);
  const [chatOpenVersion, setChatOpenVersion] = useState(0);
  const lastStreamEventId = useRef(0);
  const liveRunningRef = useRef(false);
  const selectedProjectCwdRef = useRef(null);
  const selectedThreadIdRef = useRef(null);

  const api = useMemo(() => serverUrl.replace(/\/$/, ""), [serverUrl]);
  const selectedThread = detail?.thread;
  const selectedProject = projects.find((project) => project.cwd === selectedProjectCwd) || null;
  const selectedModelInfo = models.find((model) => model.id === selectedModel || model.model === selectedModel) || null;
  const rawConversation = useMemo(() => conversationFromTurns(detail?.turns), [detail]);
  const liveText = useMemo(() => formatLiveText(liveDelta), [liveDelta]);
  const conversation = useMemo(() => {
    const baseConversation = ((liveRunning || liveText) && selectedThreadId)
      ? trimTrailingAssistantMessage(rawConversation)
      : rawConversation;
    const visibleNotices = localNotices.filter((item) => item.threadId === selectedThreadId);
    return [...baseConversation, ...visibleNotices];
  }, [liveRunning, liveText, rawConversation, selectedThreadId, localNotices]);
  const connected = status.startsWith("已连接");
  const setLiveRunningState = useCallback((value) => {
    liveRunningRef.current = value;
    setLiveRunning(value);
  }, []);

  const pushLocalNotice = useCallback((text, kind = "system") => {
    if (!selectedThreadIdRef.current || !text) return;
    setLocalNotices((items) => {
      const next = items.filter((item) => item.threadId !== selectedThreadIdRef.current);
      next.push({
        id: `local-${Date.now()}-${Math.random().toString(16).slice(2)}`,
        role: kind,
        text,
        threadId: selectedThreadIdRef.current,
      });
      return next;
    });
  }, []);

  const clearLocalNotices = useCallback((threadId = selectedThreadIdRef.current) => {
    if (!threadId) return;
    setLocalNotices((items) => items.filter((item) => item.threadId !== threadId));
  }, []);

  useEffect(() => {
    selectedProjectCwdRef.current = selectedProjectCwd;
    selectedThreadIdRef.current = selectedThreadId;
  }, [selectedProjectCwd, selectedThreadId]);

  useEffect(() => {
    let cancelled = false;
    const applyUrl = (value) => {
      if (!value) return;
      try {
        const parsed = new URL(value);
        const nextServerUrl = parsed.searchParams.get("serverUrl");
        const nextToken = parsed.searchParams.get("token");
        if (cancelled || (!nextServerUrl && !nextToken)) return;
        if (nextServerUrl) {
          setServerUrl(nextServerUrl);
          setDraftServerUrl(nextServerUrl);
        }
        if (nextToken) {
          setAuthToken(nextToken);
          setDraftAuthToken(nextToken);
        }
        setConnectionVersion((version) => version + 1);
      } catch {}
    };
    Linking.getInitialURL().then(applyUrl).catch(() => {});
    const subscription = Linking.addEventListener?.("url", (event) => applyUrl(event.url));
    return () => {
      cancelled = true;
      subscription?.remove?.();
    };
  }, []);

  const request = useCallback(async (endpoint, options = {}) => {
    const response = await fetch(`${api}${endpoint}`, {
      ...options,
      headers: {
        "content-type": "application/json",
        ...(authToken ? { Authorization: `Bearer ${authToken}` } : {}),
        ...(options.headers || {}),
      },
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  }, [api, authToken]);

  const loadThread = useCallback(async (threadId, options = {}) => {
    if (!options.force && liveRunningRef.current && threadId === selectedThreadIdRef.current) return null;
    try {
      const result = await request(threadEndpoint(threadId));
      setDetail(result);
      const errorText = latestTurnErrorText(result.turns || []);
      if (errorText) setStatus(`任务失败：${errorText}`);
      return result;
    } catch (error) {
      setStatus(`读取会话失败：${error.message}`);
      return null;
    }
  }, [request]);

  const openThread = useCallback(async (thread, projectCwd) => {
    setSelectedProjectCwd(projectCwd || thread.cwd || null);
    setSelectedThreadId(thread.id);
    setChatOpenVersion((version) => version + 1);
    setCreatingNew(false);
    setDrawerOpen(false);
    clearLocalNotices(thread.id);
    await loadThread(thread.id);
  }, [clearLocalNotices, loadThread]);

  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      await request(ENDPOINTS.health);
      const [result, modelResult] = await Promise.all([
        request(ENDPOINTS.projects),
        request(ENDPOINTS.models).catch(() => null),
      ]);
      const nextProjects = result.data || [];
      const nextThreads = nextProjects.flatMap((project) => project.threads || []);
      const nextModels = (modelResult?.data || []).filter((model) => !model.hidden);
      setProjects(nextProjects);
      setThreads(nextThreads);
      setModels(nextModels);
      setSelectedModel((value) => value || nextModels.find((model) => model.isDefault)?.id || nextModels[0]?.id || "");
      if (selectedProjectCwd && !nextProjects.some((project) => project.cwd === selectedProjectCwd)) {
        setSelectedProjectCwd(null);
      }
      setStatus(`已连接 · ${new Date().toLocaleTimeString()}`);
      if (!selectedThreadId && !creatingNew && nextThreads[0]) {
        await openThread(nextThreads[0], nextThreads[0].cwd);
      }
    } catch (error) {
      setStatus(`连接失败：${error.message}`);
    } finally {
      setBusy(false);
    }
  }, [creatingNew, openThread, request, selectedProjectCwd, selectedThreadId]);

  useEffect(() => { refresh(); }, [serverUrl, authToken, connectionVersion]);

  useEffect(() => {
    if (!selectedThreadId) return undefined;
    const timer = setInterval(() => {
      if (!liveRunningRef.current) loadThread(selectedThreadId);
    }, 3000);
    return () => clearInterval(timer);
  }, [loadThread, selectedThreadId]);

  useEffect(() => {
    let closed = false;
    let stop = null;
    let retryTimer = null;
    const applyProjects = (nextProjects) => {
      const nextThreads = nextProjects.flatMap((project) => project.threads || []);
      setProjects(nextProjects);
      setThreads(nextThreads);
      const currentProject = selectedProjectCwdRef.current;
      if (currentProject && !nextProjects.some((project) => project.cwd === currentProject)) setSelectedProjectCwd(null);
      const currentThread = selectedThreadIdRef.current;
      if (currentThread && !liveRunningRef.current && nextThreads.some((thread) => thread.id === currentThread)) loadThread(currentThread);
    };
    const connect = () => {
      stop = openSse(`${api}${ENDPOINTS.events}`, authToken, {
        onOpen: () => setStatus("已连接 · 实时同步"),
        onEvent: (event) => {
          if (event.event === "threads/changed") {
            try {
              const data = JSON.parse(event.data);
              applyProjects(data.projects || []);
            } catch {
              setStatus("实时列表同步失败");
            }
            return;
          }
          if (event.event !== "notification") return;
          let notification;
          try { notification = JSON.parse(event.data); } catch { return; }
          const threadId = notificationThreadId(notification);
          if (!threadId || threadId !== selectedThreadIdRef.current) return;
          if (notification.method === "turn/started") {
            setLiveRunningState(true);
          }
          if (notification.method === "turn/failed" || notification.method === "turn/interrupted" || notification.method === "turn/cancelled" || notification.method === "turn/canceled") {
            setLiveRunningState(false);
            setLiveDelta("");
            const errorText = notificationErrorText(notification);
            if (errorText) {
              setStatus(`任务失败：${errorText}`);
              pushLocalNotice(errorText, "error");
            }
            loadThread(threadId, { force: true });
          }
          if (notification.method === "turn/completed") {
            const errorText = notificationErrorText(notification);
            setLiveRunningState(false);
            setLiveDelta("");
            if (errorText) {
              setStatus(`任务失败：${errorText}`);
              pushLocalNotice(errorText, "error");
            } else {
              clearLocalNotices(threadId);
            }
            loadThread(threadId, { force: true });
          }
          if (notification.method === "thread/archived" || notification.method === "thread/name/updated") {
            loadThread(threadId);
          }
        },
        onDisconnect: (error) => {
          if (closed) return;
          if (error.message.includes("401")) {
            setStatus("实时总线认证失败：请确认 Token");
            return;
          }
          setStatus(`实时总线断开：${error.message}`);
          retryTimer = setTimeout(connect, 2000);
        },
      });
    };
    connect();
    return () => {
      closed = true;
      if (retryTimer) clearTimeout(retryTimer);
      stop?.();
    };
  }, [api, authToken, connectionVersion, loadThread, setLiveRunningState]);

  useEffect(() => {
    setLiveRunningState(selectedThread?.status?.type === "active");
  }, [selectedThread?.status?.type, setLiveRunningState]);

  useEffect(() => {
    if (!selectedThreadId) {
      setLiveDelta("");
      setLiveRunningState(false);
      return undefined;
    }
    let closed = false;
    let stop = null;
    let retryTimer = null;
    lastStreamEventId.current = 0;
    setLiveDelta("");
    setLiveRunningState(selectedThread?.status?.type === "active");

    const connect = () => {
      const url = `${api}${threadStreamEndpoint(selectedThreadId)}`;
      stop = openSse(url, authToken, {
        onOpen: () => setStatus((value) => value.startsWith("连接失败") ? "已连接 · 实时同步" : value),
        onEvent: (event) => {
          const eventId = Number(event.id || 0);
          if (eventId && eventId <= lastStreamEventId.current) return;
          if (eventId) lastStreamEventId.current = eventId;
          if (event.event === "error") {
            try { setStatus(`实时订阅失败：${JSON.parse(event.data).message}`); } catch { setStatus("实时订阅失败"); }
            return;
          }
          if (event.event !== "notification") return;
          let notification;
          try { notification = JSON.parse(event.data); } catch { return; }
          const params = notification.params || {};
          if (notification.method === "turn/started") {
            setLiveRunningState(true);
          }
          if (notification.method === "item/agentMessage/delta") {
            setLiveRunningState(true);
            setLiveDelta((value) => value + (params.delta || ""));
          }
          if (notification.method === "turn/failed" || notification.method === "turn/interrupted" || notification.method === "turn/cancelled" || notification.method === "turn/canceled") {
            setLiveRunningState(false);
            setLiveDelta("");
            const errorText = notificationErrorText(notification);
            if (errorText) {
              setStatus(`任务失败：${errorText}`);
              pushLocalNotice(errorText, "error");
            }
            loadThread(selectedThreadId, { force: true });
          }
          if (notification.method === "turn/completed") {
            const errorText = notificationErrorText(notification);
            setLiveRunningState(false);
            setLiveDelta("");
            if (errorText) {
              setStatus(`任务失败：${errorText}`);
              pushLocalNotice(errorText, "error");
            } else {
              clearLocalNotices(selectedThreadId);
            }
            loadThread(selectedThreadId, { force: true });
          }
          if (notification.method === "thread/archived" || notification.method === "thread/name/updated") {
            loadThread(selectedThreadId);
          }
        },
        onDisconnect: (error) => {
          if (closed) return;
          if (error.message.includes("401")) {
            setStatus("实时订阅认证失败：请确认 Token");
            return;
          }
          setStatus(`实时连接断开：${error.message}`);
          retryTimer = setTimeout(connect, 2000);
        },
      });
    };
    connect();
    return () => {
      closed = true;
      if (retryTimer) clearTimeout(retryTimer);
      stop?.();
    };
  }, [api, authToken, connectionVersion, loadThread, selectedThreadId, selectedThread?.status?.type, setLiveRunningState]);

  const startNewChat = (projectCwd = selectedProjectCwd) => {
    setSelectedProjectCwd(projectCwd || null);
    setSelectedThreadId(null);
    setDetail(null);
    setMessage("");
    setLiveDelta("");
    setLocalNotices([]);
    setCreatingNew(true);
    setDrawerOpen(false);
  };

  const sendMessage = async () => {
    const prompt = message.trim();
    if (!prompt) return;
    setBusy(true);
    setLiveRunningState(true);
    setLiveDelta("");
    clearLocalNotices(selectedThreadId);
    try {
      if (!selectedThreadId) {
        const result = await request(ENDPOINTS.threads, {
          method: "POST",
          body: JSON.stringify({ prompt, cwd: selectedProjectCwd || undefined, model: selectedModel || undefined }),
        });
        setMessage("");
        setCreatingNew(false);
        if (result.thread?.id) {
          selectedThreadIdRef.current = result.thread.id;
          setSelectedThreadId(result.thread.id);
          setDetail({ thread: result.thread, turns: [] });
        }
        await refresh();
      } else {
        await request(threadEndpoint(selectedThreadId, "message"), {
          method: "POST",
          body: JSON.stringify({ message: prompt, model: selectedModel || undefined }),
        });
        setMessage("");
        await loadThread(selectedThreadId);
      }
    } catch (error) {
      setLiveRunningState(false);
      const errorText = error?.message || "发送失败";
      pushLocalNotice(errorText, "error");
      setStatus(`发送失败：${error.message}`);
    } finally {
      setBusy(false);
    }
  };

  const stopThread = async () => {
    if (!selectedThreadId) return;
    setBusy(true);
    setLiveRunningState(false);
    setLiveDelta("");
    try {
      await request(threadEndpoint(selectedThreadId, "stop"), { method: "POST" });
      setStatus("已请求停止当前任务");
    } catch (error) {
      setStatus(`停止失败：${error.message}`);
    } finally {
      await loadThread(selectedThreadId, { force: true });
      await refresh();
      setBusy(false);
    }
  };

  const archiveThread = async (threadId) => {
    try {
      await request(threadEndpoint(threadId, "archive"), { method: "POST" });
      if (threadId === selectedThreadId) startNewChat(selectedProjectCwd);
      await refresh();
    } catch (error) {
      setStatus(`归档失败：${error.message}`);
    }
  };

  const openSettings = () => {
    setDraftServerUrl(serverUrl);
    setDraftAuthToken(authToken);
    setDraftSelectedModel(selectedModel);
    setSettingsOpen(true);
  };

  const saveSettings = () => {
    setServerUrl(draftServerUrl.trim() || defaultServerUrl);
    setAuthToken(draftAuthToken.trim());
    setSelectedModel(draftSelectedModel);
    setConnectionVersion((value) => value + 1);
    setSettingsOpen(false);
  };

  const title = selectedThread?.name || selectedThread?.preview || (creatingNew ? "新对话" : "Cloudex");

  return (
    <SafeAreaView style={styles.safe}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={styles.app}>
        <Header
          connected={connected}
          onMenu={() => setDrawerOpen(true)}
          onSettings={openSettings}
          projectName={selectedProject?.name}
          title={title}
        />
        <ChatWindow
          busy={busy}
          chatOpenVersion={chatOpenVersion}
          conversation={conversation}
          creatingNew={creatingNew}
          message={message}
          onChangeMessage={setMessage}
          onSend={sendMessage}
          onStop={stopThread}
          projectName={selectedProject?.name}
          thread={selectedThread}
          liveText={liveText}
          liveRunning={liveRunning}
        />
      </KeyboardAvoidingView>

      <NavigationDrawer
        onArchive={archiveThread}
        onClose={() => setDrawerOpen(false)}
        onNewChat={startNewChat}
        onOpenThread={openThread}
        onRefresh={refresh}
        onSelectProject={setSelectedProjectCwd}
        projects={projects}
        selectedProject={selectedProject}
        selectedThreadId={selectedThreadId}
        threads={threads}
        visible={drawerOpen}
      />

      <SettingsModal
        authToken={draftAuthToken}
        models={models}
        onChangeAuthToken={setDraftAuthToken}
        onChangeServerUrl={setDraftServerUrl}
        onClose={() => setSettingsOpen(false)}
        onSave={saveSettings}
        onSelectModel={setDraftSelectedModel}
        selectedModel={draftSelectedModel}
        serverUrl={draftServerUrl}
        status={status}
        visible={settingsOpen}
      />
    </SafeAreaView>
  );
}

function Header({ connected, onMenu, onSettings, projectName, title }) {
  return (
    <View style={styles.header}>
      <Pressable accessibilityLabel="打开项目菜单" onPress={onMenu} style={styles.headerButton}>
        <Text style={styles.headerIcon}>☰</Text>
      </Pressable>
      <View style={styles.headerCenter}>
        <Text numberOfLines={1} style={styles.headerTitle}>{title}</Text>
        <View style={styles.headerSubtitleRow}>
          <View style={[styles.connectionDot, connected ? styles.connectedDot : styles.disconnectedDot]} />
          <Text numberOfLines={1} style={styles.headerSubtitle}>{projectName || "选择项目"}</Text>
        </View>
      </View>
      <Pressable accessibilityLabel="打开设置" onPress={onSettings} style={styles.headerButton}>
        <Text style={styles.headerIcon}>⚙︎</Text>
      </Pressable>
    </View>
  );
}

function ChatWindow({ busy, chatOpenVersion, conversation, creatingNew, liveText, liveRunning, message, onChangeMessage, onSend, onStop, projectName, thread }) {
  const active = liveRunning || thread?.status?.type === "active";
  const messagesRef = useRef(null);
  const scrollToLatestRef = useRef(false);

  useEffect(() => {
    if (!thread) return;
    scrollToLatestRef.current = true;
    const frame = requestAnimationFrame(() => {
      messagesRef.current?.scrollToEnd({ animated: false });
      scrollToLatestRef.current = false;
    });
    return () => cancelAnimationFrame(frame);
  }, [chatOpenVersion, thread?.id]);

  const handleContentSizeChange = useCallback(() => {
    if (!scrollToLatestRef.current) return;
    messagesRef.current?.scrollToEnd({ animated: false });
    scrollToLatestRef.current = false;
  }, []);

  return (
    <View style={styles.chatWindow}>
      <ScrollView
        contentContainerStyle={styles.messages}
        keyboardShouldPersistTaps="handled"
        onContentSizeChange={handleContentSizeChange}
        ref={messagesRef}
      >
        {!thread && conversation.length === 0 && (
          <View style={styles.welcome}>
            <Text style={styles.welcomeTitle}>{creatingNew ? "开始新对话" : "选择一个对话"}</Text>
            <Text style={styles.welcomeText}>
              {projectName ? `当前项目：${projectName}` : "点击左上角菜单选择电脑上的项目和历史对话。"}
            </Text>
          </View>
        )}
        {thread && (
          <View style={styles.threadMeta}>
            <Text style={styles.threadStatus}>{statusText(thread)} · {formatDate(thread.updatedAt)}</Text>
            <Text numberOfLines={2} style={styles.threadPath}>{thread.cwd}</Text>
          </View>
        )}
        {conversation.map((item) => (
          <View key={item.id} style={[styles.messageBubble, item.role === "user" ? styles.userMessage : item.role === "error" ? styles.errorMessage : styles.agentMessage]}>
            <Text style={[styles.messageRole, item.role === "error" && styles.errorRole]}>{item.role === "user" ? "你" : item.role === "assistant" ? "Codex" : item.role === "error" ? "错误" : "系统"}</Text>
            <Text style={[styles.messageText, item.role === "error" && styles.errorText]}>{item.text}</Text>
          </View>
        ))}
        {!!liveText && (
          <View style={[styles.messageBubble, styles.agentMessage]}>
            <Text style={styles.messageRole}>Codex</Text>
            <Text style={styles.messageText}>{liveText}</Text>
          </View>
        )}
        {active && <ActivityIndicator color="#111" style={styles.runningIndicator} />}
      </ScrollView>

      <View style={styles.composerWrap}>
        <TextInput
          multiline
          onChangeText={onChangeMessage}
          placeholder={thread ? "继续发送指令…" : "向 Codex 发送新指令…"}
          style={styles.composerInput}
          value={message}
        />
        <Pressable disabled={busy || !message.trim()} onPress={onSend} style={[styles.sendButton, (!message.trim() || busy) && styles.disabledButton]}>
          {busy ? <ActivityIndicator color="#fff" size="small" /> : <Text style={styles.sendText}>↑</Text>}
        </Pressable>
        {active && <Pressable onPress={onStop} style={styles.stopButton}><Text style={styles.stopText}>■</Text></Pressable>}
      </View>
    </View>
  );
}

function NavigationDrawer({ onArchive, onClose, onNewChat, onOpenThread, onRefresh, onSelectProject, projects, selectedProject, selectedThreadId, threads, visible }) {
  const visibleThreads = selectedProject?.threads || threads;
  return (
    <Modal animationType="fade" onRequestClose={onClose} transparent visible={visible}>
      <View style={styles.drawerOverlay}>
        <View style={styles.drawer}>
          <View style={styles.drawerHeader}>
            <Text style={styles.drawerTitle}>项目与对话</Text>
            <Pressable onPress={onClose}><Text style={styles.closeText}>×</Text></Pressable>
          </View>
          <Pressable onPress={() => onNewChat(selectedProject?.cwd)} style={styles.newChatButton}>
            <Text style={styles.newChatText}>＋ 新对话</Text>
          </Pressable>
          <View style={styles.drawerSectionHeader}>
            {selectedProject ? (
              <Pressable onPress={() => onSelectProject(null)}><Text style={styles.drawerLink}>‹ 全部项目</Text></Pressable>
            ) : <Text style={styles.drawerSectionTitle}>电脑上的项目</Text>}
            <Pressable onPress={onRefresh}><Text style={styles.drawerLink}>刷新</Text></Pressable>
          </View>

          <ScrollView contentContainerStyle={styles.drawerList}>
            {!selectedProject && projects.map((project) => (
              <Pressable key={project.cwd} onPress={() => onSelectProject(project.cwd)} style={styles.projectRow}>
                <View style={styles.projectGlyph}><Text style={styles.projectGlyphText}>{project.name.slice(0, 1).toUpperCase()}</Text></View>
                <View style={styles.projectRowText}>
                  <Text numberOfLines={1} style={styles.projectName}>{project.name}</Text>
                  <Text numberOfLines={1} style={styles.projectCwd}>{project.cwd}</Text>
                  <Text style={styles.projectCount}>{project.threads.length} 个对话</Text>
                </View>
                <Text style={styles.chevron}>›</Text>
              </Pressable>
            ))}

            {selectedProject && <Text style={styles.selectedProjectTitle}>{selectedProject.name}</Text>}
            {selectedProject && visibleThreads.length === 0 && <Text style={styles.emptyText}>这个项目还没有对话</Text>}
            {selectedProject && visibleThreads.map((thread) => (
              <Pressable
                key={thread.id}
                onPress={() => onOpenThread(thread, selectedProject.cwd)}
                style={[styles.threadRow, selectedThreadId === thread.id && styles.selectedThreadRow]}
              >
                <View style={styles.threadRowText}>
                  <Text numberOfLines={2} style={styles.threadName}>{thread.name || thread.preview || "未命名对话"}</Text>
                  <Text style={styles.threadDate}>{formatDate(thread.updatedAt)}</Text>
                </View>
                <Pressable onPress={(event) => { event.stopPropagation?.(); onArchive(thread.id); }}><Text style={styles.archiveText}>归档</Text></Pressable>
              </Pressable>
            ))}
          </ScrollView>
        </View>
        <Pressable onPress={onClose} style={styles.drawerBackdrop} />
      </View>
    </Modal>
  );
}

function SettingsModal({ authToken, models, onChangeAuthToken, onChangeServerUrl, onClose, onSave, onSelectModel, selectedModel, serverUrl, status, visible }) {
  return (
    <Modal animationType="fade" onRequestClose={onClose} transparent visible={visible}>
      <KeyboardAvoidingView behavior={Platform.OS === "ios" ? "padding" : undefined} style={styles.modalOverlay}>
        <View style={styles.settingsCard}>
          <View style={styles.drawerHeader}>
            <Text style={styles.settingsTitle}>设置</Text>
            <Pressable onPress={onClose}><Text style={styles.closeText}>×</Text></Pressable>
          </View>
          <Text style={styles.settingLabel}>本地服务器地址</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            onChangeText={onChangeServerUrl}
            placeholder="http://192.168.x.x:8787"
            style={styles.settingInput}
            value={serverUrl}
          />
          <Text style={styles.settingLabel}>访问 Token</Text>
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            onChangeText={onChangeAuthToken}
            placeholder="AUTH_TOKEN"
            secureTextEntry
            style={styles.settingInput}
            value={authToken}
          />
          <Text style={styles.settingLabel}>默认模型</Text>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.modelPills}>
            {models.map((model) => {
              const id = model.id || model.model;
              const active = selectedModel === id || selectedModel === model.model;
              return (
                <Pressable key={id} onPress={() => onSelectModel(id)} style={[styles.modelPill, active && styles.selectedModelPill]}>
                  <Text style={[styles.modelPillText, active && styles.selectedModelPillText]}>{model.displayName || id}</Text>
                </Pressable>
              );
            })}
            {models.length === 0 && <Text style={styles.emptyText}>连接后自动读取可用模型</Text>}
          </ScrollView>
          <Text style={styles.settingsStatus}>{status}</Text>
          <Pressable onPress={onSave} style={styles.saveButton}><Text style={styles.saveText}>保存并连接</Text></Pressable>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: "#fff" },
  app: { flex: 1 },
  header: { alignItems: "center", borderBottomColor: "#e7e7e7", borderBottomWidth: StyleSheet.hairlineWidth, flexDirection: "row", minHeight: 58, paddingHorizontal: 10 },
  headerButton: { alignItems: "center", height: 44, justifyContent: "center", width: 44 },
  headerIcon: { color: "#202020", fontSize: 25 },
  headerCenter: { alignItems: "center", flex: 1, paddingHorizontal: 8 },
  headerTitle: { color: "#171717", fontSize: 16, fontWeight: "700", maxWidth: "100%" },
  headerSubtitleRow: { alignItems: "center", flexDirection: "row", gap: 5, marginTop: 2 },
  headerSubtitle: { color: "#777", fontSize: 11, maxWidth: 180 },
  connectionDot: { borderRadius: 4, height: 7, width: 7 },
  connectedDot: { backgroundColor: "#23a55a" },
  disconnectedDot: { backgroundColor: "#d64b4b" },
  chatWindow: { flex: 1 },
  messages: { flexGrow: 1, gap: 12, padding: 16, paddingBottom: 24 },
  welcome: { alignItems: "center", flex: 1, justifyContent: "center", minHeight: 380, paddingHorizontal: 28 },
  welcomeTitle: { color: "#222", fontSize: 25, fontWeight: "700" },
  welcomeText: { color: "#777", fontSize: 14, lineHeight: 21, marginTop: 10, textAlign: "center" },
  threadMeta: { alignItems: "center", gap: 4, marginBottom: 6 },
  threadStatus: { color: "#777", fontSize: 11 },
  threadPath: { color: "#888", fontSize: 11, textAlign: "center" },
  messageBubble: { borderRadius: 16, gap: 5, maxWidth: "90%", paddingHorizontal: 14, paddingVertical: 11 },
  userMessage: { alignSelf: "flex-end", backgroundColor: "#e8e8e8" },
  agentMessage: { alignSelf: "flex-start", backgroundColor: "#f7f7f7" },
  errorMessage: { alignSelf: "flex-start", backgroundColor: "#fff1f1", borderColor: "#f0b8b8", borderWidth: 1 },
  messageRole: { color: "#666", fontSize: 11, fontWeight: "600" },
  errorRole: { color: "#b42318" },
  messageText: { color: "#171717", fontSize: 15, lineHeight: 22 },
  errorText: { color: "#8f1d1d" },
  runningIndicator: { marginVertical: 8 },
  composerWrap: { alignItems: "flex-end", backgroundColor: "#fff", borderColor: "#ddd", borderRadius: 24, borderWidth: 1, flexDirection: "row", gap: 8, marginBottom: 10, marginHorizontal: 12, padding: 7 },
  composerInput: { flex: 1, fontSize: 15, maxHeight: 130, minHeight: 38, paddingHorizontal: 9, paddingVertical: 9, textAlignVertical: "top" },
  sendButton: { alignItems: "center", backgroundColor: "#111", borderRadius: 19, height: 38, justifyContent: "center", width: 38 },
  disabledButton: { backgroundColor: "#aaa" },
  sendText: { color: "#fff", fontSize: 22, fontWeight: "700", lineHeight: 24 },
  stopButton: { alignItems: "center", borderColor: "#c44", borderRadius: 19, borderWidth: 1, height: 38, justifyContent: "center", width: 38 },
  stopText: { color: "#c44", fontSize: 13 },
  drawerOverlay: { flex: 1, flexDirection: "row" },
  drawer: { backgroundColor: "#f7f7f8", elevation: 8, paddingHorizontal: 14, paddingTop: 48, shadowColor: "#000", shadowOffset: { height: 0, width: 2 }, shadowOpacity: 0.18, shadowRadius: 10, width: "88%" },
  drawerBackdrop: { backgroundColor: "rgba(0,0,0,0.34)", flex: 1 },
  drawerHeader: { alignItems: "center", flexDirection: "row", justifyContent: "space-between" },
  drawerTitle: { color: "#171717", fontSize: 23, fontWeight: "700" },
  closeText: { color: "#444", fontSize: 32, fontWeight: "300", paddingHorizontal: 8 },
  newChatButton: { alignItems: "center", backgroundColor: "#111", borderRadius: 12, marginTop: 18, paddingVertical: 13 },
  newChatText: { color: "#fff", fontSize: 15, fontWeight: "600" },
  drawerSectionHeader: { alignItems: "center", flexDirection: "row", justifyContent: "space-between", marginTop: 20 },
  drawerSectionTitle: { color: "#555", fontSize: 13, fontWeight: "700", textTransform: "uppercase" },
  drawerLink: { color: "#2463eb", fontSize: 14, fontWeight: "600" },
  drawerList: { gap: 8, paddingBottom: 40, paddingTop: 10 },
  projectRow: { alignItems: "center", backgroundColor: "#fff", borderRadius: 12, flexDirection: "row", gap: 11, padding: 12 },
  projectGlyph: { alignItems: "center", backgroundColor: "#dce9ff", borderRadius: 9, height: 38, justifyContent: "center", width: 38 },
  projectGlyphText: { color: "#2359a6", fontSize: 17, fontWeight: "700" },
  projectRowText: { flex: 1 },
  projectName: { color: "#222", fontSize: 15, fontWeight: "600" },
  projectCwd: { color: "#888", fontSize: 10, marginTop: 2 },
  projectCount: { color: "#666", fontSize: 11, marginTop: 3 },
  chevron: { color: "#888", fontSize: 24 },
  selectedProjectTitle: { color: "#222", fontSize: 20, fontWeight: "700", paddingBottom: 4 },
  emptyText: { color: "#777", paddingVertical: 20, textAlign: "center" },
  threadRow: { alignItems: "center", backgroundColor: "#fff", borderRadius: 10, flexDirection: "row", gap: 10, padding: 12 },
  selectedThreadRow: { backgroundColor: "#e8eef9" },
  threadRowText: { flex: 1 },
  threadName: { color: "#222", fontSize: 14, fontWeight: "500", lineHeight: 19 },
  threadDate: { color: "#888", fontSize: 10, marginTop: 4 },
  archiveText: { color: "#b54a4a", fontSize: 11 },
  modalOverlay: { alignItems: "center", backgroundColor: "rgba(0,0,0,0.38)", flex: 1, justifyContent: "center", padding: 20 },
  settingsCard: { backgroundColor: "#fff", borderRadius: 18, gap: 11, padding: 20, width: "100%" },
  settingsTitle: { color: "#171717", fontSize: 23, fontWeight: "700" },
  settingLabel: { color: "#444", fontSize: 13, fontWeight: "600", marginTop: 5 },
  settingInput: { backgroundColor: "#f7f7f7", borderColor: "#ddd", borderRadius: 10, borderWidth: 1, minHeight: 45, paddingHorizontal: 12 },
  modelPills: { gap: 8, paddingVertical: 3 },
  modelPill: { borderColor: "#d8d8d8", borderRadius: 999, borderWidth: 1, paddingHorizontal: 12, paddingVertical: 8 },
  selectedModelPill: { backgroundColor: "#111", borderColor: "#111" },
  modelPillText: { color: "#222", fontSize: 13, fontWeight: "600" },
  selectedModelPillText: { color: "#fff" },
  settingsStatus: { color: "#777", fontSize: 12, marginTop: 2 },
  saveButton: { alignItems: "center", backgroundColor: "#111", borderRadius: 11, marginTop: 8, paddingVertical: 13 },
  saveText: { color: "#fff", fontSize: 15, fontWeight: "600" },
});

registerRootComponent(App);
