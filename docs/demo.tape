# Regenerate the README GIF:  vhs docs/demo.tape   (needs `brew install vhs` and a release build)
# The recording is sped up 5x; every number in it is measured live.
Output docs/demo.gif

Set Shell zsh
Set FontSize 15
Set Width 1000
Set Height 560
Set Padding 18
Set TypingSpeed 120ms
Set PlaybackSpeed 5

Hide
Type "export PATH=$PWD/.build/release:$PATH PS1='%F{green}$%f ' && ./scripts/demo-setup.sh && clear"
Enter
Sleep 8s
Show

Type "nohog scan --count /tmp/nohog-demo"
Enter
Sleep 15s

Type "nohog bench 3000"
Enter
Wait+Screen@300s /background:/
Sleep 25s
