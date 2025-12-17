# AR Asset Explorer 🚀

A professional, cross-platform Flutter application that allows users to explore a dynamic cloud library of 3D assets and visualize them in real-world environments using Augmented Reality (AR). 

This project demonstrates a hybrid cloud architecture, utilizing **Firebase** for identity management and **Supabase** for high-performance 3D asset delivery.

---

---

## ✨ Key Features

* **Secure Authentication:** Full signup/login flow powered by **Firebase Auth**.
* **Dynamic Asset Discovery:** Fetches GLB models and matching thumbnails in real-time from **Supabase Storage**.
* **Advanced AR Controller:**
    * **Plane Detection:** Real-time surface mapping.
    * **Intuitive Gestures:** Move, Rotate (accumulated angle logic), and Scale.
    * **State Persistence:** A unique "Refresh" logic that rebuilds nodes from internal state to mitigate Sceneform crashes.
* **Robust Service Layer:** * Smart caching via `flutter_cache_manager`.
    * **GLB Validation:** Header checks ('glTF') and JSON chunk inspection before loading to prevent runtime errors.
* **Optimized Search:** Instant, case-insensitive filtering for large asset libraries.

---

## 🏗 System Architecture

The app follows a service-oriented architecture to separate UI from heavy AR and Network logic.



### Workflow
1.  **Initialize:** App bootstraps Firebase and Supabase concurrently.
2.  **Auth:** User authenticates via Firebase.
3.  **Browse:** `AssetLibraryPage` queries Supabase for available `.glb` files.
4.  **Fetch & Validate:** `ARModelManager` downloads the model, verifies the file integrity, and caches it locally.
5.  **Render:** `ARCameraPage` injects the local file path into the ARCore scene.

---

## 🛠 Tech Stack & Dependencies

### Core Technologies
* **Framework:** Flutter
* **Backend (Auth):** Firebase
* **Backend (Storage):** Supabase
* **AR Engine:** ARCore (via `arcore_flutter_plugin`)
