import React, { useCallback, useEffect, useMemo, useState } from "react";
import { registerRootComponent } from "expo";
import {
  ActivityIndicator,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { ENDPOINTS, threadEndpoint, withQuery } from "@cloudex/shared";

const defaultServerUrl = "http://127.0.0.1:8787";

export default function App() {
  const [serverUrl, setServerUrl] = useState(defaultServerUrl);
  const [authToken, setAuthToken] = useState("");
  const [prompt, setPrompt] = useState("");
  const [threads, setThreads] = useState([]);
  const [status, setStatus] = useState("未连接");
  const [busy, setBusy] = useState(false);

  const api = useMemo(() => serverUrl.replace(/\/$/, ""), [serverUrl]);

  const request = useCallback(async (endpoint, options) => {
    const response = await fetch(`${api}${endpoint}`, {
      headers: {
        "content-type": "application/json",
        ...(authToken ? { Authorization: `Bearer ${authToken}` } : {}),
        ...(options?.headers || {}),
      },
      ...options,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  }, [api, authToken]);

  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      await request(ENDPOINTS.health);
      const result = await request(withQuery(ENDPOINTS.threads, { archived: false }));
      setThreads(result.data || []);
      setStatus(`已连接 · ${new Date().toLocaleTimeString()}`);
    } catch (error) {
      setStatus(`连接失败：${error.message}`);
    } finally {
      setBusy(false);
    }
  }, [request]);

  useEffect(() => { refresh(); }, [refresh]);

  const createThread = async () => {
    if (!prompt.trim()) return;
    setBusy(true);
    try {
      await request(ENDPOINTS.threads, {
        method: "POST",
        body: JSON.stringify({ prompt: prompt.trim() }),
      });
      setPrompt("");
      await refresh();
    } catch (error) {
      setStatus(`创建失败：${error.message}`);
      setBusy(false);
    }
  };

  const archive = async (threadId) => {
    try {
      await request(threadEndpoint(threadId, "archive"), { method: "POST" });
      await refresh();
    } catch (error) {
      setStatus(`归档失败：${error.message}`);
    }
  };

  return (
    <SafeAreaView style={styles.safe}>
      <ScrollView contentContainerStyle={styles.container}>
        <Text style={styles.title}>Cloudex</Text>
        <Text style={styles.subtitle}>Codex 本地控制</Text>

        <Text style={styles.label}>本地服务器地址</Text>
        <TextInput
          autoCapitalize="none"
          autoCorrect={false}
          onChangeText={setServerUrl}
          style={styles.input}
          value={serverUrl}
        />
        <Text style={styles.status}>{status}</Text>

        <Text style={styles.label}>访问 Token（可选）</Text>
        <TextInput
          autoCapitalize="none"
          autoCorrect={false}
          onChangeText={setAuthToken}
          placeholder="Tailscale 模式填写 AUTH_TOKEN"
          secureTextEntry
          style={styles.input}
          value={authToken}
        />

        <Text style={styles.label}>新建任务</Text>
        <TextInput
          multiline
          onChangeText={setPrompt}
          placeholder="输入要发送给 Codex 的指令"
          style={[styles.input, styles.prompt]}
          value={prompt}
        />
        <Pressable disabled={busy} onPress={createThread} style={styles.primaryButton}>
          {busy ? <ActivityIndicator color="#fff" /> : <Text style={styles.primaryText}>创建并发送</Text>}
        </Pressable>

        <View style={styles.row}>
          <Text style={styles.sectionTitle}>任务</Text>
          <Pressable onPress={refresh}><Text style={styles.link}>刷新</Text></Pressable>
        </View>
        {threads.length === 0 && <Text style={styles.empty}>暂无未归档任务</Text>}
        {threads.map((thread) => (
          <View key={thread.id} style={styles.card}>
            <Text numberOfLines={1} style={styles.cardTitle}>{thread.name || thread.preview || "未命名任务"}</Text>
            <Text numberOfLines={1} style={styles.cardMeta}>{thread.id}</Text>
            <Pressable onPress={() => archive(thread.id)}><Text style={styles.danger}>归档</Text></Pressable>
          </View>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: "#f7f7f8" },
  container: { gap: 12, padding: 20, paddingBottom: 40 },
  title: { color: "#171717", fontSize: 32, fontWeight: "700" },
  subtitle: { color: "#666", fontSize: 16, marginBottom: 12 },
  label: { color: "#333", fontSize: 14, fontWeight: "600", marginTop: 8 },
  input: { backgroundColor: "#fff", borderColor: "#ddd", borderRadius: 10, borderWidth: 1, minHeight: 44, padding: 12 },
  prompt: { minHeight: 92, textAlignVertical: "top" },
  status: { color: "#666", fontSize: 13 },
  primaryButton: { alignItems: "center", backgroundColor: "#111", borderRadius: 10, minHeight: 46, justifyContent: "center" },
  primaryText: { color: "#fff", fontWeight: "600" },
  row: { alignItems: "center", flexDirection: "row", justifyContent: "space-between", marginTop: 16 },
  sectionTitle: { fontSize: 20, fontWeight: "700" },
  link: { color: "#2463eb", fontWeight: "600" },
  empty: { color: "#777", paddingVertical: 18 },
  card: { backgroundColor: "#fff", borderRadius: 12, gap: 6, padding: 14 },
  cardTitle: { fontSize: 16, fontWeight: "600" },
  cardMeta: { color: "#888", fontSize: 11 },
  danger: { color: "#c33", fontSize: 13, marginTop: 4 },
});

registerRootComponent(App);
