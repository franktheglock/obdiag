/**
 * Single place where the Firebase Admin SDK is initialised, so every module
 * shares one app instance (the Admin SDK throws if you initialise twice).
 */

import { initializeApp, getApps, App } from "firebase-admin/app";
import { getFirestore, Firestore } from "firebase-admin/firestore";
import { getAuth, Auth } from "firebase-admin/auth";
import { FIRESTORE_DATABASE_ID } from "./config";

const app: App = getApps()[0] ?? initializeApp();

// Standard edition uses the `(default)` database; an Enterprise database has a
// named id and must be addressed explicitly. See FIRESTORE_DATABASE_ID.
export const db: Firestore = FIRESTORE_DATABASE_ID
  ? getFirestore(app, FIRESTORE_DATABASE_ID)
  : getFirestore(app);
export const auth: Auth = getAuth(app);

// Undefined fields would otherwise be rejected by Firestore on write.
db.settings({ ignoreUndefinedProperties: true });
