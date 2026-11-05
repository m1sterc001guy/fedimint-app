// dart format width=80
// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'statechain.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$StatecoinExitState {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'StatecoinExitState()';
}


}

/// @nodoc
class $StatecoinExitStateCopyWith<$Res>  {
$StatecoinExitStateCopyWith(StatecoinExitState _, $Res Function(StatecoinExitState) __);
}


/// @nodoc


class StatecoinExitState_AwaitingNodeConfirmation extends StatecoinExitState {
  const StatecoinExitState_AwaitingNodeConfirmation(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState_AwaitingNodeConfirmation);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'StatecoinExitState.awaitingNodeConfirmation()';
}


}




/// @nodoc


class StatecoinExitState_Timelocked extends StatecoinExitState {
  const StatecoinExitState_Timelocked({required this.blocksRemaining}): super._();
  

 final  int blocksRemaining;

/// Create a copy of StatecoinExitState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$StatecoinExitState_TimelockedCopyWith<StatecoinExitState_Timelocked> get copyWith => _$StatecoinExitState_TimelockedCopyWithImpl<StatecoinExitState_Timelocked>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState_Timelocked&&(identical(other.blocksRemaining, blocksRemaining) || other.blocksRemaining == blocksRemaining));
}


@override
int get hashCode => Object.hash(runtimeType,blocksRemaining);

@override
String toString() {
  return 'StatecoinExitState.timelocked(blocksRemaining: $blocksRemaining)';
}


}

/// @nodoc
abstract mixin class $StatecoinExitState_TimelockedCopyWith<$Res> implements $StatecoinExitStateCopyWith<$Res> {
  factory $StatecoinExitState_TimelockedCopyWith(StatecoinExitState_Timelocked value, $Res Function(StatecoinExitState_Timelocked) _then) = _$StatecoinExitState_TimelockedCopyWithImpl;
@useResult
$Res call({
 int blocksRemaining
});




}
/// @nodoc
class _$StatecoinExitState_TimelockedCopyWithImpl<$Res>
    implements $StatecoinExitState_TimelockedCopyWith<$Res> {
  _$StatecoinExitState_TimelockedCopyWithImpl(this._self, this._then);

  final StatecoinExitState_Timelocked _self;
  final $Res Function(StatecoinExitState_Timelocked) _then;

/// Create a copy of StatecoinExitState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? blocksRemaining = null,}) {
  return _then(StatecoinExitState_Timelocked(
blocksRemaining: null == blocksRemaining ? _self.blocksRemaining : blocksRemaining // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class StatecoinExitState_Ready extends StatecoinExitState {
  const StatecoinExitState_Ready(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState_Ready);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'StatecoinExitState.ready()';
}


}




/// @nodoc


class StatecoinExitState_ExitBroadcast extends StatecoinExitState {
  const StatecoinExitState_ExitBroadcast(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState_ExitBroadcast);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'StatecoinExitState.exitBroadcast()';
}


}




/// @nodoc


class StatecoinExitState_Completed extends StatecoinExitState {
  const StatecoinExitState_Completed(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is StatecoinExitState_Completed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'StatecoinExitState.completed()';
}


}




// dart format on
