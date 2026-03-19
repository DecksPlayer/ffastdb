import 'package:ffastdb/src/serialization/type_adapter.dart';

class User {
  final String name;
  final int age;
  final String email;

  User({required this.name, required this.age, required this.email});

  @override
  String toString() => 'User(name: $name, age: $age, email: $email)';
}

class UserAdapter extends TypeAdapter<User> {
  @override
  int get typeId => 10; // Custom ID for User type

  @override
  User read(BinaryReader reader) {
    final name = reader.readString();
    final age = reader.readUint32();
    final email = reader.readString();
    return User(name: name, age: age, email: email);
  }

  @override
  void write(BinaryWriter writer, User obj) {
    writer.writeString(obj.name);
    writer.writeUint32(obj.age);
    writer.writeString(obj.email);
  }
}
