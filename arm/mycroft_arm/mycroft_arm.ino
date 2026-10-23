// Mycroft arm firmware: hobby servos on an Arduino (Uno, Nano, Mega) or ESP32, driven over USB serial.
//
// Protocol, one command per line at 115200 baud; every command answers one line, "OK ..." or "ERR ...":
//   PING                 -> OK mycroft-arm <joints>
//   MOVE <joint> <deg>   -> OK         start moving one joint (clamped to its limits)
//   SPEED <deg_per_s>    -> OK         10..180, for every joint
//   HOME                 -> OK         all joints to their home angles
//   STOP                 -> OK         freeze where they are now
//   POS                  -> OK a0 a1 ...   current angles, joint order as below
//   MOVING               -> OK 0|1
//   RELAX                -> OK         detach servos (go limp; careful, the arm may drop)
// Joints are numbered from 0. Change the table below to match your arm; keep Mycroft's arm.json in step.

#include <Servo.h>   // on ESP32 install "ESP32Servo" and include <ESP32Servo.h> instead

struct Joint { const char *name; uint8_t pin; int minDeg, maxDeg, homeDeg; };

Joint joints[] = {
  {"base",        3,  0, 180, 90},
  {"shoulder",    5, 15, 165, 90},
  {"elbow",       6, 15, 165, 90},
  {"wrist_pitch", 9,  0, 180, 90},
  {"wrist_roll", 10,  0, 180, 90},
  {"gripper",    11, 10, 120, 60},
};
const int N = sizeof(joints) / sizeof(joints[0]);

Servo servos[N];
float pos[N];
int target[N];
float speed = 60;            // degrees per second
unsigned long lastStep = 0;
bool attached = false;
char line[48];
int len = 0;

void attachAll() {
  if (attached) return;
  for (int i = 0; i < N; i++) servos[i].attach(joints[i].pin);
  attached = true;
}

void setup() {
  Serial.begin(115200);
  for (int i = 0; i < N; i++) { pos[i] = joints[i].homeDeg; target[i] = joints[i].homeDeg; }
  attachAll();
  for (int i = 0; i < N; i++) servos[i].write(joints[i].homeDeg);
  lastStep = millis();
}

int clampJoint(int i, int deg) { return constrain(deg, joints[i].minDeg, joints[i].maxDeg); }

bool moving() {
  for (int i = 0; i < N; i++) if (abs(pos[i] - target[i]) > 0.5) return true;
  return false;
}

void handle(char *cmd) {
  char *verb = strtok(cmd, " ");
  if (!verb) return;
  if (!strcmp(verb, "PING")) { Serial.print("OK mycroft-arm "); Serial.println(N); }
  else if (!strcmp(verb, "MOVE")) {
    char *j = strtok(NULL, " "), *d = strtok(NULL, " ");
    if (!j || !d) { Serial.println("ERR usage: MOVE <joint> <deg>"); return; }
    int i = atoi(j);
    if (i < 0 || i >= N) { Serial.println("ERR no such joint"); return; }
    attachAll();
    target[i] = clampJoint(i, atoi(d));
    Serial.print("OK "); Serial.println(target[i]);
  }
  else if (!strcmp(verb, "SPEED")) {
    char *v = strtok(NULL, " ");
    if (!v) { Serial.println("ERR usage: SPEED <deg_per_s>"); return; }
    speed = constrain(atoi(v), 10, 180);
    Serial.println("OK");
  }
  else if (!strcmp(verb, "HOME")) { attachAll(); for (int i = 0; i < N; i++) target[i] = joints[i].homeDeg; Serial.println("OK"); }
  else if (!strcmp(verb, "STOP")) { for (int i = 0; i < N; i++) target[i] = (int)round(pos[i]); Serial.println("OK"); }
  else if (!strcmp(verb, "POS")) {
    Serial.print("OK");
    for (int i = 0; i < N; i++) { Serial.print(' '); Serial.print((int)round(pos[i])); }
    Serial.println();
  }
  else if (!strcmp(verb, "MOVING")) { Serial.print("OK "); Serial.println(moving() ? 1 : 0); }
  else if (!strcmp(verb, "RELAX")) {
    for (int i = 0; i < N; i++) { servos[i].detach(); target[i] = (int)round(pos[i]); }
    attached = false;
    Serial.println("OK");
  }
  else Serial.println("ERR unknown command");
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (len) { line[len] = 0; handle(line); len = 0; }
    } else if (len < (int)sizeof(line) - 1) line[len++] = c;
  }
  // Every 20 ms, step each joint toward its target at the set speed, so moves are smooth.
  unsigned long now = millis();
  if (now - lastStep >= 20) {
    float step = speed * (now - lastStep) / 1000.0;
    lastStep = now;
    if (!attached) return;
    for (int i = 0; i < N; i++) {
      float diff = target[i] - pos[i];
      if (fabs(diff) <= step) pos[i] = target[i]; else pos[i] += diff > 0 ? step : -step;
      servos[i].write((int)round(pos[i]));
    }
  }
}
