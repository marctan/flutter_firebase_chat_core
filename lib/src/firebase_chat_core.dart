import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'firebase_chat_core_config.dart';
import 'util.dart';

/// Provides access to Firebase chat data. Singleton, use
/// FirebaseChatCore.instance to aceess methods.
class FirebaseChatCore {
  FirebaseChatCore._privateConstructor() {
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      firebaseUser = user;
    });
  }

  /// Config to set custom names for rooms and users collections. Also
  /// see [FirebaseChatCoreConfig].
  FirebaseChatCoreConfig config = const FirebaseChatCoreConfig(
    null,
    'rooms',
    'users',
  );

  /// Current logged in user in Firebase. Does not update automatically.
  /// Use [FirebaseAuth.authStateChanges] to listen to the state changes.
  User? firebaseUser = FirebaseAuth.instance.currentUser;

  /// Singleton instance.
  static final FirebaseChatCore instance =
      FirebaseChatCore._privateConstructor();

  /// Gets proper [FirebaseFirestore] instance.
  FirebaseFirestore getFirebaseFirestore() => config.firebaseAppName != null
      ? FirebaseFirestore.instanceFor(
          app: Firebase.app(config.firebaseAppName!),
        )
      : FirebaseFirestore.instance;

  /// Sets custom config to change default names for rooms
  /// and users collections. Also see [FirebaseChatCoreConfig].
  void setConfig(FirebaseChatCoreConfig firebaseChatCoreConfig) {
    config = firebaseChatCoreConfig;
  }

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    required String currentUserId,
    types.Role creatorRole = types.Role.admin,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    final currentUser = await fetchUser(
      getFirebaseFirestore(),
      currentUserId,
      config.usersCollectionName,
      role: creatorRole.toShortString(),
    );

    final roomUsers = [types.User.fromJson(currentUser)] + users;

    final room = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .add({
      'createdAt': FieldValue.serverTimestamp(),
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, user) => {
          ...previousValue,
          user.id: user.role?.toShortString(),
        },
      ),
    });

    return types.Room(
      id: room.id,
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    String currentUserId,
    types.User otherUser, {
    bool temporary = false,
    Map<String, dynamic>? metadata,
  }) async {
    // Sort two user ids array to always have the same array for both users,
    // this will make it easy to find the room if exist and make one read only.
    final userIds = [currentUserId, otherUser.id]..sort();

    final roomQuery = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('type', isEqualTo: types.RoomType.direct.toShortString())
        .where('userIds', isEqualTo: userIds)
        .limit(1)
        .get();

    // Check if room already exist.
    if (roomQuery.docs.isNotEmpty) {
      final room = (await processRoomsQuery(
        currentUserId,
        getFirebaseFirestore(),
        roomQuery,
        config.usersCollectionName,
      ))
          .first;

      return room;
    }

    // To support old chats created without sorted array,
    // try to check the room by reversing user ids array.
    final oldRoomQuery = await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('type', isEqualTo: types.RoomType.direct.toShortString())
        .where('userIds', isEqualTo: userIds.reversed.toList())
        .limit(1)
        .get();

    // Check if room already exist.
    if (oldRoomQuery.docs.isNotEmpty) {
      final room = (await processRoomsQuery(
        currentUserId,
        getFirebaseFirestore(),
        oldRoomQuery,
        config.usersCollectionName,
      ))
          .first;

      return room;
    }

    final currentUser = await fetchUser(
      getFirebaseFirestore(),
      currentUserId,
      config.usersCollectionName,
    );

    final users = [types.User.fromJson(currentUser), otherUser];

    if (!temporary) {
      // Create new room with sorted user ids array.
      final room = await getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .add({
        'createdAt': FieldValue.serverTimestamp(),
        'imageUrl': null,
        'metadata': metadata,
        'name': null,
        'type': types.RoomType.direct.toShortString(),
        'updatedAt': FieldValue.serverTimestamp(),
        'userIds': userIds,
        'userRoles': null,
      });

      return types.Room(
        id: room.id,
        metadata: metadata,
        type: types.RoomType.direct,
        users: users,
      );
    } else {
      //don't create room yet
      return types.Room(
        id: 'temporary',
        metadata: metadata,
        type: types.RoomType.direct,
        users: users,
      );
    }
  }

  /// Creates [types.User] in Firebase to store name and avatar used on
  /// rooms list
  Future<void> createUserInFirestore(
    types.User user, {
    String? userName,
    String? number,
  }) async {
    await getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .doc(user.id)
        .set({
      'createdAt': FieldValue.serverTimestamp(),
      'firstName': user.firstName,
      'imageUrl': user.imageUrl,
      'lastName': user.lastName,
      'lastSeen': FieldValue.serverTimestamp(),
      'metadata': user.metadata,
      'role': user.role?.toShortString(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (userName != null) 'userName': userName,
      if (number != null) 'number': number,
    });
  }

  /// Removes message document.
  Future<void> deleteMessage(String roomId, String messageId) async {
    await getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/$roomId/messages')
        .doc(messageId)
        .delete();
  }

  /// Removes room document.
  Future<void> deleteRoom(String roomId) async {
    await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .doc(roomId)
        .delete();
  }

  /// Removes [types.User] from `users` collection in Firebase.
  Future<void> deleteUserFromFirestore(String userId) async {
    await getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .doc(userId)
        .delete();
  }

  /// Returns a stream of messages from Firebase for a given room.
  Stream<List<types.Message>> messages(
    types.Room room,
    String currentUserId, {
    List<Object?>? endAt,
    List<Object?>? endBefore,
    int? limit,
    List<Object?>? startAfter,
    List<Object?>? startAt,
  }) {
    var query = getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/${room.id}/messages')
        .orderBy('createdAt', descending: true);

    if (endAt != null) {
      query = query.endAt(endAt);
    }

    if (endBefore != null) {
      query = query.endBefore(endBefore);
    }

    if (limit != null) {
      query = query.limit(limit);
    }

    if (startAfter != null) {
      query = query.startAfter(startAfter);
    }

    if (startAt != null) {
      query = query.startAt(startAt);
    }

    final deletedInfo = room.metadata?['deletedInfo'];
    if (deletedInfo != null) {
      if (currentUserId == deletedInfo?['userId']) {
        query = query.where(
          'createdAt',
          isGreaterThan: deletedInfo?['deletedDate'],
        );
      }
    }

    return query.snapshots().map(
          (snapshot) => snapshot.docs.fold<List<types.Message>>(
            [],
            (previousValue, doc) {
              final data = doc.data();
              final author = room.users.firstWhere(
                (u) => u.id == data['authorId'],
                orElse: () => types.User(id: data['authorId'] as String),
              );

              data['author'] = author.toJson();
              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
              data['id'] = doc.id;
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

              return [...previousValue, types.Message.fromJson(data)];
            },
          ),
        );
  }

  /// Returns a stream of changes in a room from Firebase.
  Stream<types.Room> room(String roomId, String currentUserId) =>
      getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .doc(roomId)
          .snapshots()
          .asyncMap(
            (doc) => processRoomDocument(
              doc,
              currentUserId,
              getFirebaseFirestore(),
              config.usersCollectionName,
            ),
          );

  /// Returns a stream of rooms from Firebase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`
  Stream<List<types.Room>> rooms(
    String currentUserId,
  ) {
    final collection = getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .where('userIds', arrayContains: currentUserId)
        .orderBy('updatedAt', descending: true);

    return collection.snapshots().asyncMap(
          (query) => processRoomsQuery(
            currentUserId,
            getFirebaseFirestore(),
            query,
            config.usersCollectionName,
          ),
        );
  }

  /// Sends a message to the Firestore. Accepts any partial message and a
  /// room ID. If arbitraty data is provided in the [partialMessage]
  /// does nothing.
  void sendMessage(
    String currentUserId,
    String userName,
    dynamic partialMessage,
    String roomId, {
    types.Message? repliedMessage,
  }) async {
    types.Message? message;

    if (partialMessage is types.PartialCustom) {
      message = types.CustomMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialCustom: partialMessage,
        status: types.Status.delivered,
      );
    } else if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialFile: partialMessage,
        status: types.Status.delivered,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialImage: partialMessage,
        status: types.Status.delivered,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialText: partialMessage,
        status: types.Status.delivered,
      );
    } else if (partialMessage is types.PartialAudio) {
      message = types.AudioMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialAudio: partialMessage,
        status: types.Status.delivered,
      );
    } else if (partialMessage is types.PartialVideo) {
      message = types.VideoMessage.fromPartial(
        author: types.User(id: currentUserId),
        id: '',
        partialVideo: partialMessage,
        status: types.Status.delivered,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['authorId'] = currentUserId;
      messageMap['createdAt'] = FieldValue.serverTimestamp();
      messageMap['updatedAt'] = FieldValue.serverTimestamp();
      messageMap['metadata'] = {'userName': userName, 'pinnedDate': null};
      messageMap['groupSeenById'] = [];

      if (repliedMessage != null) {
        // final textMessage = repliedMessage as types.TextMessage;
        messageMap['repliedMessage'] = repliedMessage.toJson();
      }

      if ((await Connectivity().checkConnectivity()) ==
          ConnectivityResult.none) {
        messageMap['status'] = 'error';
      }
      await getFirebaseFirestore()
          .collection('${config.roomsCollectionName}/$roomId/messages')
          .add(messageMap);

      await getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .doc(roomId)
          .update({'updatedAt': FieldValue.serverTimestamp()});

      await getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .doc(roomId)
          .update({'metadata.unRead': true});

      await getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .doc(roomId)
          .update({'metadata.senderId': currentUserId});

      await getFirebaseFirestore()
          .collection(config.roomsCollectionName)
          .doc(roomId)
          .update({'metadata.deletedByUserId': FieldValue.delete()});
    }
  }

  /// Updates a message in the Firestore. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  void updateMessage(
    String currentUserId,
    types.Message message,
    String roomId,
  ) async {
    if (message.author.id != currentUserId) return;

    final messageMap = message.toJson();
    messageMap.removeWhere(
      (key, value) => key == 'author' || key == 'createdAt' || key == 'id',
    );
    messageMap['authorId'] = message.author.id;
    messageMap['updatedAt'] = FieldValue.serverTimestamp();

    await getFirebaseFirestore()
        .collection('${config.roomsCollectionName}/$roomId/messages')
        .doc(message.id)
        .update(messageMap);
  }

  /// Updates a room in the Firestore. Accepts any room.
  /// Room will probably be taken from the [rooms] stream.
  void updateRoom(types.Room room) async {
    final roomMap = room.toJson();
    roomMap.removeWhere((key, value) =>
        key == 'createdAt' ||
        key == 'id' ||
        key == 'lastMessages' ||
        key == 'users');

    if (room.type == types.RoomType.direct) {
      roomMap['imageUrl'] = null;
      roomMap['name'] = null;
    }

    roomMap['lastMessages'] = room.lastMessages?.map((m) {
      final messageMap = m.toJson();

      messageMap.removeWhere((key, value) =>
          key == 'author' ||
          key == 'createdAt' ||
          key == 'id' ||
          key == 'updatedAt');

      messageMap['authorId'] = m.author.id;

      return messageMap;
    }).toList();
    roomMap['updatedAt'] = FieldValue.serverTimestamp();
    roomMap['userIds'] = room.users.map((u) => u.id).toList();

    await getFirebaseFirestore()
        .collection(config.roomsCollectionName)
        .doc(room.id)
        .update(roomMap);
  }

  /// Returns a stream of all users from Firebase.
  Stream<List<types.User>> users() {
    if (firebaseUser == null) return const Stream.empty();
    return getFirebaseFirestore()
        .collection(config.usersCollectionName)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.fold<List<types.User>>(
            [],
            (previousValue, doc) {
              if (firebaseUser!.uid == doc.id) return previousValue;

              final data = doc.data();

              data['createdAt'] = data['createdAt']?.millisecondsSinceEpoch;
              data['id'] = doc.id;
              data['lastSeen'] = data['lastSeen']?.millisecondsSinceEpoch;
              data['updatedAt'] = data['updatedAt']?.millisecondsSinceEpoch;

              return [...previousValue, types.User.fromJson(data)];
            },
          ),
        );
  }
}
