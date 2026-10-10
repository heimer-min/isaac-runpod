# Isaac Sim Script Editor에서 실행: /clock 토픽을 발행하는 OmniGraph를 만든다.
import omni.graph.core as og

keys = og.Controller.Keys
og.Controller.edit(
    {"graph_path": "/ActionGraph", "evaluator_name": "execution"},
    {
        keys.CREATE_NODES: [
            ("OnPlaybackTick", "omni.graph.action.OnPlaybackTick"),
            ("ReadSimTime", "isaacsim.core.nodes.IsaacReadSimulationTime"),
            ("PublishClock", "isaacsim.ros2.bridge.ROS2PublishClock"),
        ],
        keys.CONNECT: [
            ("OnPlaybackTick.outputs:tick", "PublishClock.inputs:execIn"),
            ("ReadSimTime.outputs:simulationTime", "PublishClock.inputs:timeStamp"),
        ],
    },
)
print("ROS2 clock graph created. Press Play, then run: ros2 topic list")
