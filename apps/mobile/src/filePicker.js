import * as DocumentPicker from "expo-document-picker";

export async function pickLocalFile() {
  const result = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: false, multiple: false });
  if (result.canceled) return null;
  return result.assets[0] || null;
}
