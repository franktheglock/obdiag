/**
 * Single place where the Firebase Admin SDK is initialised, so every module
 * shares one app instance (the Admin SDK throws if you initialise twice).
 */

import { initializeApp, getApps, App } from "firebase-admin/app";
import { getFirestore, Firestore } from "firebase-admin/firestore";
import { getAuth, Auth } from "firebase-admin/auth";

const app: App = getApps()[0] ?? initializeApp();

export const db: Firestore = getFirestore(app);
export const auth: Auth = getAuth(app);

// Undefined fields would otherwise be rejected by Firestore on write.
db.settings({ ignoreUndefinedProperties: true });
