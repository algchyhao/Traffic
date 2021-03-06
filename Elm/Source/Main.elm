module Main exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.Lazy exposing (..)
import Http
import Task
import Json.Decode as Decode exposing (decodeString)
import Json.Encode exposing (encode)
import Svg as S
import Svg.Attributes as Sa
import Window
import Time exposing (Time)
import Mouse
import Keyboard
import WebSocket

import List.Extra exposing (isSuffixOf)

import Base exposing (..)
import TrafficRenderer exposing (..)
import MenuRenderer exposing (renderMenu)
import JsonParser exposing (..)

import Debug

type alias Flags =
    { webSocketUrl : String
    , controls : Controls
    }

main =
    Html.programWithFlags { init = init, view = view, update = update, subscriptions = subscriptions }


init : Flags -> ( Model, Cmd Msg )
init flags =
    (
        { cars = []
        , roads = []
        , err = Nothing
        , size = Nothing
        , lasttime = Nothing
        , scroll = {x=0, y=0}
        , dragMouse = Nothing
        , mouse = Nothing
        , renderScale = 40.0
        , webSocketUrl = flags.webSocketUrl
        , ip = Nothing
        , accelRate = 6.0
        , steerRate = 200.0
        , lastClickTime = Nothing
        , trackingCar = Nothing
        , controls = flags.controls
        , others = []
        , keyCombo = []
        , keyComboTimeLeft = 0
        , currentDragCar = Nothing
        , hiddenRoads = []
        , snap = False
        , buildingRoad = False
        , buildingRoadStart = Nothing
        , selectState = NotSelecting
        , currentSelectedRoad = Nothing
        , otherRoad = Nothing
        , cmdLog = []
        , popup = NoPopup
        , menu = defaultMenu
        }
    , Task.perform identity <| Task.succeed CheckSize
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ServerSync json ->
            let result = decodeString decodeTraffic json
            in case result of
                Ok traffic ->
                    ( { model
                        | cars = traffic.cars
                        , roads = traffic.roads
                        , others = traffic.others
                        , ip = Just traffic.ip
                        , err = Nothing
                        , menu = let menu = model.menu
                                 in { menu
                                    | buttons = generateMenuButtons traffic
                                    }
                    }
                    , Task.perform identity <| Task.succeed FixScroll )
                Err error ->
                    let cmdRes = decodeString decodeRes json
                    in case cmdRes of
                        Ok res ->
                            ( { model | cmdLog = model.cmdLog ++ ["  " ++ res.cmd] } 
                            , Cmd.none )
                        Err _ ->
                            ( { model
                                | err = Just error
                            }
                            , Cmd.none )

        Resize size ->
            ( { model | size = Just { x = toFloat size.width, y = toFloat size.height } }, Cmd.none )

        CheckSize ->
            ( model, Task.perform Resize <| Window.size )

        UpdateClient time ->
            case model.lasttime of
                Nothing ->
                    ( { model | lasttime = Just time }, Cmd.none )

                Just lasttime ->
                    let
                        delta =
                            Time.inSeconds (time - lasttime)
                    in
                        ( { model
                            | lasttime = Just time
                            , keyComboTimeLeft = if model.keyComboTimeLeft > 0 then model.keyComboTimeLeft - delta else 0
                            , keyCombo = if model.keyComboTimeLeft > 0 then model.keyCombo else []
                            , cars =
                                List.map (\car ->
                                        { car
                                            | pos =
                                                pAdd car.pos <| (\( x, y ) -> { x = x, y = y }) <| fromPolar ( car.speed * delta, degrees car.rot )
                                            , speed = (if car.handBreaks then car.speed * (car.breakStrength ^ delta) else car.speed) + car.accel * delta
                                            , rot = car.rot + car.steering * delta
                                            , steering =
                                                case model.err of
                                                    Just _  -> car.steering / (2 ^ delta)
                                                    Nothing -> car.steering
                                        }
                                    )
                                    model.cars
                            , menu = let menu = model.menu
                                     in { menu
                                        | rotation = case menu.state of
                                            In -> if menu.rotation > 0 then menu.rotation - delta * 5 else 0
                                            Out -> if menu.rotation < 1 then menu.rotation + delta * 5 else 1
                                        }
                          }
                        , Task.perform identity <| Task.succeed FixScroll
                        )

        FixScroll ->
            ( {model | scroll =
                case (model.size, model.trackingCar) of
                    (Just size, Just carName) ->
                        let car_ = List.head <| List.filter (\car -> car.name == carName) model.cars
                        in case car_ of
                            Just car -> { x = -car.pos.x * model.renderScale + size.x / 2, y = -car.pos.y * model.renderScale + size.y / 2 }
                            Nothing -> model.scroll
                    _ -> model.scroll

              }, Cmd.none )

        MouseRelease _ ->
            case model.popup of
                NoPopup ->
                    ( {model | dragMouse = Nothing, lastClickTime = model.lasttime}, Cmd.none )
                _ -> ( model, Cmd.none )

        MousePress pos ->
            case model.popup of
                NoPopup ->
                    if model.buildingRoad then
                        case model.buildingRoadStart of
                            Nothing ->
                                let start = { x = (toFloat pos.x - model.scroll.x) / model.renderScale
                                            , y = (toFloat pos.y - model.scroll.y) / model.renderScale }
                                    start_ = if model.snap then pRound start else start
                                in  ( { model
                                    | buildingRoadStart = Just start_
                                    }, Cmd.none )
                            Just start ->
                                ( { model
                                | buildingRoadStart = Nothing
                                , buildingRoad = False
                                },
                                case model.mouse of
                                    Just mouse ->
                                        let mouse_ = if model.snap then pRound mouse else mouse
                                        in WebSocket.send model.webSocketUrl
                                            <| String.join "/"
                                            [ "rbuild"
                                            , toString <| start.x
                                            , toString <| start.y
                                            , toString <| mouse_.x
                                            , toString <| mouse_.y
                                            ]
                                    Nothing -> Cmd.none
                                )
                    else case model.selectState of
                        CombineSelecting ->
                            case (model.currentSelectedRoad, model.otherRoad) of
                                (Just road, Nothing) ->
                                    ( { model
                                    | otherRoad = Just road
                                    }
                                    , Cmd.none )
                                (Just road, Just other) ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    , otherRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl
                                        <| String.join "/"
                                        [ "rconn"
                                        , other.id
                                        , road.id
                                        ]
                                    )
                                _ -> ( model, Cmd.none )

                        RemoveSelecting ->
                            case model.currentSelectedRoad of
                                Nothing -> ( model, Cmd.none )
                                Just road ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl <| "rrm/" ++ road.id
                                    )
                        FlipSelecting ->
                            case model.currentSelectedRoad of
                                Nothing -> ( model, Cmd.none )
                                Just road ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl <| "rflip/" ++ road.id
                                    )
                        HideSelecting ->
                            case model.currentSelectedRoad of
                                Nothing -> ( model, Cmd.none )
                                Just road ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    , hiddenRoads =
                                        if List.member road.id model.hiddenRoads then List.filter (\x -> x /= road.id) model.hiddenRoads
                                        else List.append model.hiddenRoads [road.id]
                                    }
                                    , Cmd.none
                                    )
                        LightSelecting lState ->
                            case model.currentSelectedRoad of
                                Nothing -> ( model, Cmd.none )
                                Just road ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl <|
                                        case lState of
                                            AddLight -> "lbuild/" ++ road.id
                                            RemoveLight -> "lrm/" ++ road.id
                                            FlipLight -> "lflip/" ++ road.id
                                    )
                        TrackSelecting ->
                            case model.mouse of
                                Nothing -> ( model, Cmd.none )
                                Just pos ->
                                    let closest = getClosestCar pos model.cars
                                    in case closest of
                                        Nothing -> ( model, Cmd.none )
                                        Just car ->
                                            ( { model
                                            | selectState = NotSelecting
                                            , trackingCar = Just car.name
                                            }
                                            , Cmd.none
                                            )
                        IntersectionMakeSelecting ->
                            case (model.currentSelectedRoad, model.otherRoad) of
                                (Just road, Nothing) ->
                                    ( { model
                                    | otherRoad = Just road
                                    }
                                    , Cmd.none )
                                (Just road, Just other) ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    , otherRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl
                                        <| String.join "/"
                                        [ "intermake"
                                        , other.id
                                        , road.id
                                        ]
                                    )
                                _ -> ( model, Cmd.none )

                        AICarSelecting ->
                            case (model.currentSelectedRoad, model.otherRoad) of
                                (Just road, Nothing) ->
                                    ( { model
                                    | otherRoad = Just road
                                    }
                                    , Cmd.none )
                                (Just road, Just other) ->
                                    ( { model
                                    | selectState = NotSelecting
                                    , currentSelectedRoad = Nothing
                                    , otherRoad = Nothing
                                    }
                                    , WebSocket.send model.webSocketUrl
                                        <| String.join "/"
                                        [ "createai"
                                        , other.id
                                        , road.id
                                        ]
                                    )
                                _ -> ( model, Cmd.none )

                        NotSelecting ->
                            ( {model
                                | dragMouse = Just {x = toFloat pos.x, y = toFloat pos.y}
                                , currentDragCar = Nothing}
                            , case model.currentDragCar of
                                Just car -> WebSocket.send model.webSocketUrl <| "create/" ++ (Http.encodeUri <| encode 0 <| encodeProtoCar car)
                                Nothing -> Cmd.none
                            )
                _ -> ( model, Cmd.none )

        MouseMove pos ->
            case model.popup of
                NoPopup ->
                    let
                        track = case model.trackingCar of
                            Nothing -> False
                            Just name -> List.length (List.filter (\car -> car.name == name) model.cars) > 0

                        mouse = { x = (toFloat pos.x - model.scroll.x) / model.renderScale
                                , y = (toFloat pos.y - model.scroll.y) / model.renderScale }

                        model_ = {model
                                 | mouse = Just mouse
                                 , currentSelectedRoad =
                                     if model.selectState /= NotSelecting && model.selectState /= TrackSelecting then
                                         getClosestRoad mouse <| List.filter (\road -> not <| List.member road.id model.hiddenRoads) model.roads
                                     else model.currentSelectedRoad
                                 }

                    in if not track then
                        case model_.dragMouse of
                            Just mousePos ->
                                let delta = {x = toFloat pos.x - mousePos.x, y = toFloat pos.y - mousePos.y}
                                in ( {model_ | scroll = {x = model_.scroll.x + delta.x, y = model_.scroll.y + delta.y}, dragMouse = Just {x = toFloat pos.x, y = toFloat pos.y}}, Cmd.none )
                            Nothing ->
                                case model_.currentDragCar of
                                    Just car ->
                                        ( { model_
                                        | currentDragCar = Just {car | pos = {x = (toFloat pos.x - model_.scroll.x) / model_.renderScale, y = (toFloat pos.y - model_.scroll.y) / model_.renderScale}}
                                        }, Cmd.none )
                                    Nothing -> ( model_, Cmd.none )
                    else ( model_, Cmd.none )
                _ -> ( model, Cmd.none )

        KeyCodeDown code ->
            case keyboardMap !! code of
                Just key -> update (KeyDown key) model
                Nothing -> ( model, Cmd.none )

        KeyCodeUp code ->
            case keyboardMap !! code of
                Just key -> update (KeyUp key) model
                Nothing -> ( model, Cmd.none )

        KeyDown key ->
            if key == model.controls.free then
                    ( {model
                    | trackingCar = Nothing
                    , currentDragCar = Nothing
                    , buildingRoad = False
                    , buildingRoadStart = Nothing
                    , selectState = NotSelecting
                    , currentSelectedRoad = Nothing
                    , otherRoad = Nothing
                    , popup = NoPopup
                    , keyCombo = []
                    , menu =
                        let menu = model.menu
                        in { menu | state = In }
                    }, Cmd.none )
            else
            case model.popup of
                NoPopup ->
                    if key == model.controls.zoomIn then -- Plus key
                        ( {model
                            | renderScale = model.renderScale * zoomFactor
                            , scroll =
                                case model.size of
                                    Just size ->
                                        {x = (model.scroll.x - size.x / 2) * zoomFactor + size.x / 2, y = (model.scroll.y - size.y / 2) * zoomFactor + size.y / 2}
                                    Nothing ->
                                        model.scroll
                        }, Cmd.none )
                    else if key == model.controls.zoomOut then -- Minus key
                        ( {model
                            | renderScale = model.renderScale / zoomFactor
                            , scroll =
                                case model.size of
                                    Just size ->
                                        {x = (model.scroll.x - size.x / 2) / zoomFactor + size.x / 2, y = (model.scroll.y - size.y / 2) / zoomFactor + size.y / 2}
                                    Nothing ->
                                        model.scroll
                        }, Cmd.none )
                    else case model.ip of
                        Just myIp ->
                            if key == model.controls.remove then
                                ( model
                                ,
                                    let distToScroll car = Tuple.first <| toPolar <| (car.pos.x - model.scroll.x, car.pos.y - model.scroll.y)
                                        closestCar = List.head
                                            <| List.sortWith (\c1 c2 -> compare (distToScroll c2) (distToScroll c1) )
                                            <| List.filter (\c -> c.controlledBy == model.ip) model.cars
                                    in case closestCar of
                                        Just {name} -> WebSocket.send model.webSocketUrl <| "remove/" ++ name
                                        Nothing -> Cmd.none
                                )
                            else if key == model.controls.break then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | handBreaks = True, accel = 0}
                                            Nothing -> car
                                    ) model.cars},
                                WebSocket.send model.webSocketUrl "breaks" )
                            else if key == model.controls.up then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | handBreaks = False, accel = model.accelRate}
                                            Nothing -> car
                                    ) model.cars},
                                    WebSocket.send model.webSocketUrl ( "accel/" ++ (toString model.accelRate) ) )
                            else if key == model.controls.back then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | handBreaks = False, accel = negate model.accelRate}
                                            Nothing -> car
                                    ) model.cars},
                                    WebSocket.send model.webSocketUrl ( "accel/" ++ (toString <| negate model.accelRate) ) )
                            else if key == model.controls.left then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | steering = negate model.steerRate}
                                            Nothing -> car
                                    ) model.cars},
                                    WebSocket.send model.webSocketUrl ( "steer/" ++ (toString <| negate model.steerRate)) )
                            else if key == model.controls.right then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | steering = model.steerRate}
                                            Nothing -> car
                                    ) model.cars},
                                WebSocket.send model.webSocketUrl ( "steer/" ++ (toString model.steerRate)))
                            else if key == model.controls.carUp || key == model.controls.carDown then
                                ( { model |
                                    trackingCar =
                                        let controlledByMe =
                                            List.sortWith (\car1 car2 -> compare car1.pos.x car2.pos.x) <|
                                                case model.ip of
                                                    Just ip -> List.filter (\car ->
                                                        case car.controlledBy of
                                                            Just c -> c == ip
                                                            Nothing -> False) model.cars
                                                    Nothing -> []
                                        in case model.trackingCar of
                                            Nothing -> Maybe.map .name <| List.head controlledByMe
                                            Just trackName ->
                                                let track = List.head <| List.filter (\(idx, car) -> car.name == trackName) (List.indexedMap (,) controlledByMe)
                                                in case track of
                                                    Just (idx, car) ->
                                                        let res =
                                                            if key == model.controls.carUp then
                                                                Maybe.map .name <| List.head <| List.drop (idx+1) controlledByMe
                                                            else
                                                                if idx == 0 then Nothing else Maybe.map .name <| List.head <| List.drop (idx-1) <| controlledByMe
                                                        in case res of
                                                            Just x -> Just x
                                                            Nothing ->
                                                                if key == model.controls.carUp then
                                                                    Maybe.map .name <| List.head controlledByMe
                                                                else
                                                                    Maybe.map .name <| List.head <| List.reverse controlledByMe
                                                    Nothing -> Maybe.map .name <| List.head controlledByMe
                                  }
                                  , Cmd.none )
                            else if key == model.controls.snap then
                                ( { model | snap = True }, Cmd.none )
                            else if key == model.controls.hide && model.currentSelectedRoad /= Nothing then
                                case model.currentSelectedRoad of
                                    Just road ->
                                        ( { model
                                            | hiddenRoads = model.hiddenRoads ++ [road.id]}
                                        , Cmd.none )
                                    Nothing -> ( model, Cmd.none )
                            else if key == model.controls.help then
                                ( { model | popup = InfoPopup False }, Cmd.none )
                            else
                                let currentCombo = if model.keyComboTimeLeft > 0 then model.keyCombo else []
                                    combo = Debug.log "Combo" <| currentCombo ++ [key]
                                    matching = Debug.log "Matching" <| List.filter (\button ->
                                        case button.hotKey of
                                            Just hotKey -> isSuffixOf hotKey combo
                                            Nothing -> False) model.menu.buttons
                                    sorted = Debug.log "Sorted" <| List.sortBy (negate << List.length << (Maybe.withDefault []) << .hotKey) matching
                                    first = List.head sorted
                                in 
                                   case first of
                                       Just button -> ( {model | keyCombo = [], keyComboTimeLeft = 1}, Task.perform identity <| Task.succeed button.message )
                                       Nothing -> (always ({model | keyCombo = combo, keyComboTimeLeft = 1}, Cmd.none)) <| Debug.log "Key Down" key
                        Nothing -> ( model, Cmd.none )
                _ -> ( model, Cmd.none )

        KeyUp key ->
            case model.popup of
                NoPopup ->
                    case model.ip of
                        Just myIp ->
                            if key == model.controls.break then -- k
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | handBreaks = False}
                                            Nothing -> car
                                    ) model.cars},
                                WebSocket.send model.webSocketUrl "no_breaks" )
                            else if key == model.controls.up || key == model.controls.back then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | accel = 0}
                                            Nothing -> car
                                    ) model.cars},
                                WebSocket.send model.webSocketUrl "accel/0" )
                            else if key == model.controls.left || key == model.controls.right then
                                ( { model | cars = List.map (\car ->
                                        case car.controlledBy of
                                            Just ip -> if ip /= myIp then car else
                                                          {car | steering = 0}
                                            Nothing -> car
                                    ) model.cars},
                                WebSocket.send model.webSocketUrl "steer/0" )
                            else if key == model.controls.snap then
                                ( { model | snap = False }, Cmd.none )
                            else (always (model, Cmd.none)) <| Debug.log "Key Up" key
                        Nothing -> ( model, Cmd.none )
                _ -> ( model, Cmd.none )


        MenuBallClicked ->
            ( { model
            | menu =
                let menu = model.menu
                in { menu | state = case model.menu.state of
                                                In -> Out
                                                Out -> In
            }
            }, Cmd.none )

        MenuButtonClicked msg ->
            ( { model
            | menu = let menu = model.menu
                     in { menu | state = In }
            }, Task.perform identity <| Task.succeed msg )


        AddCarClicked police ->
            ( { model
            | currentDragCar = Just {pos = {x = 0, y = 0}, img = if police then "CarPolis" else "Car1", isPolice = police}
            }, Cmd.none )

        AddRoadClicked ->
            ( { model
            | buildingRoad = True
            }
            , Cmd.none
            )

        SelectStateChange state ->
            ( { model | selectState = state }
            , Cmd.none )

        ShowRoadClicked ->
            ( { model | hiddenRoads = [] }
            , Cmd.none )

        ClosePopup ->
            ( { model
              | popup = NoPopup
            }
            , Cmd.none )

        OpenPopup pop ->
            ( { model | popup = pop }
            , Cmd.none)

        InfoToggleDebug ->
            ( { model
              | popup =
                  case model.popup of
                      InfoPopup debug -> InfoPopup <| not debug
                      _ -> model.popup
            }
            , Cmd.none )

        UpdateText text ->
            case model.popup of
                LoginPopup _ ->
                    ( { model
                    | popup = LoginPopup text
                    }
                    , Cmd.none )
                CommandPopup _ ->
                    ( { model
                    | popup = CommandPopup text
                    }
                    , Cmd.none )
                _ -> ( model, Cmd.none )

        SendCommand ->
            case model.popup of
                CommandPopup cmd ->
                    ( { model
                    | popup = CommandPopup ""
                    , cmdLog = model.cmdLog ++ [cmd]
                    }
                    , WebSocket.send model.webSocketUrl <| "cmd/" ++ cmd)
                _ -> ( model, Cmd.none )

        ClearLogs ->
            ( { model
                | cmdLog = []}
            , Cmd.none )

        Login ->
            case model.popup of
                LoginPopup name ->
                    if String.length name < nameLengthMax && String.length name > 0 then
                            ( { model
                            | popup = NoPopup
                            }
                            , WebSocket.send model.webSocketUrl <| "login/" ++ name)
                    else ( model, Cmd.none )
                _ -> ( model, Cmd.none )

view : Model -> Html Msg
view model =
    div [ style [ ("margin-top", "0px")
                , ("padding-top", "0px") ] ]
        ([ div ( [ style [ ("margin", "0px")
                        , ("top", "0px")
                        , ("position", "fixed")]
            ] ++
            case model.popup of
                NoPopup -> []
                _ -> [ class "blur" ]
            )
            [ -- Generate svg!
              S.svg
                [ Sa.width <| Maybe.withDefault "10" <| Maybe.map (toString << .x) model.size
                , Sa.height <| Maybe.withDefault "10" <| Maybe.map (toString << .y) model.size
                , Sa.style "background: #227722"
                ]
                (let
                    cars_ =
                        case (model.selectState, model.mouse) of
                            (TrackSelecting, Just pos) ->
                                case getClosestCar pos model.cars of
                                    Just closest ->
                                        List.map (\car -> if car == closest then { car | size = car.size * 1.3 } else car) model.cars
                                    Nothing -> model.cars
                            _ -> model.cars
                    lines = renderBackgroundLines model
                    roads = renderRoads model model.roads
                    cars = renderCars model cars_
                    trafficLights = renderTrafficLights model model.roads
                    menu = renderMenu model
                in
                    lines ++ roads ++ cars ++ trafficLights ++ menu
                ++ (
                    List.concatMap (\road ->
                        [ S.line
                            [ Sa.x1 <| toString <| (road.start.x * model.renderScale) + model.scroll.x
                            , Sa.y1 <| toString <| (road.start.y * model.renderScale) + model.scroll.y
                            , Sa.x2 <| toString <| (road.end.x * model.renderScale) + model.scroll.x
                            , Sa.y2 <| toString <| (road.end.y * model.renderScale) + model.scroll.y
                            , Sa.strokeWidth <| toString <| model.renderScale * 0.3
                            , Sa.stroke "green"
                            ] []
                        , S.circle
                            [ Sa.cx <| toString <| (road.end.x * model.renderScale) + model.scroll.x
                            , Sa.cy <| toString <| (road.end.y * model.renderScale) + model.scroll.y
                            , Sa.fill "yellow"
                            , Sa.r <| toString <| model.renderScale / 2
                            , Sa.stroke "black"
                            , Sa.strokeWidth <| toString <| model.renderScale / 20
                            ] []
                        ]
                    )
                    ((
                    case model.currentSelectedRoad of
                        Just road -> [road]
                        Nothing -> []
                    ) ++ (
                    case model.otherRoad of
                        Just road -> [road]
                        Nothing -> []
                    ))
                )
                ++ (
                    case model.currentDragCar of
                        Just car -> renderCars model [toCar car]
                        Nothing -> []
                )
                ++ (
                    case (model.buildingRoadStart, model.mouse) of
                        (Just start, Just mouse) ->
                            let f = if model.snap then pRound else identity
                                road = Road "" (f start) (f mouse) [] Nothing 1.5
                            in renderRoads model [road]
                        _ -> []
                )
                )
            ]
        ] ++
        (
            if model.popup == NoPopup then []
            else
               [ div [ style <| centerFill model ]
                   [div [ style (centerFill model ++
                                [ ("background-color", "#A64")
                                , ("opacity", "0.6")] )] []
                   , generatePopup model.popup model
                   ]
                ]
            )
        )

centerFill model =
    [ ("position", "absolute")
    , ("width", "100%")
    , ("height", (Maybe.withDefault "10" <| Maybe.map (toString << .y) model.size) ++ "px")]

generatePopup : Popup -> Model -> Html Msg
generatePopup popup model =
    div [style <| centerFill model]
    <| case popup of
        NoPopup -> []
        InfoPopup debug ->
            [ div [style [("text-align", "center")]] (
                [ h3 [] [pre [] [text "Keys:"]]
                , pre [] [text "+ Zoom in"]
                , pre [] [text "- Zoom out"]
                , pre [] [text "w Accelerate"]
                , pre [] [text "s Active breaks"]
                , pre [] [text "a/d Steer left/right"]
                , pre [] [text "q Drive backwards"]
                ] ++
                List.filterMap (\button ->
                    case button.hotKey of
                        Just hotKey -> Just <| pre [] [text <| button.image ++ ": " ++ String.join "-" hotKey]
                        Nothing -> Nothing
                    ) model.menu.buttons
                ++
                [ button [ onClick InfoToggleDebug ] [text <| if debug then "Hide Debug" else "Show Debug"]
                , br [] []
                ]
                ++
                (if debug then
                    [ h3 [] [pre [] [text "Debug info:"]]
                    ] ++
                    (
                    List.filterMap (\(prop, name) ->
                        case prop of
                            Just val -> Just (pre [] [text <| name ++ ": " ++ (toString val)])
                            Nothing -> Nothing
                        )
                    (
                        [ (Maybe.map toString model.ip, "Ip")
                        , (Maybe.map toString model.size, "Screen size")
                        , (Maybe.map toString model.trackingCar, "Tracking car")
                        , (Maybe.map toString model.currentSelectedRoad, "Current selected road")
                        , (Just <| toString model.keyCombo, "Current combo")
                        , (Just <| toString model.keyComboTimeLeft, "Time left on combo")
                        ]
                    )
                    ++ (
                        case model.err of
                            Just err ->
                                [ p [style [("color", "red")]] [text <| "An error occured. Error was: " ++ toString err]
                                ]
                            Nothing ->
                                []
                    )
                ) else [])
                ++ [ button [ onClick ClosePopup ] [text "Done!"] ]
            )]

        LoginPopup name ->
            [ div [style [ ("text-align", "center")
                         , ("margin-top", "200px") ]]
                [ h1 [style [("font-family", "Impact")]] [text "Username:"]
                , Html.form [ onSubmit Login ]
                (
                    [ input [ placeholder "Dabson XD"
                            , onInput UpdateText
                            , style [("font-size", "40px")]
                            ] []
                    , br [] []
                    , button [disabled <| String.length name <= 0 || String.length name >= nameLengthMax] [text "Login!"]
                    ] ++
                    [
                        if String.length name >= nameLengthMax then
                            p [style [("color", "red")]] [text "u boot too big 4 me big boi. u need 2 b less fat pls."]
                        else
                            br [] []
                    ]
                )
                ]
            ]

        CommandPopup cmd ->
            [ div [ class "cmd" ] 
                [ div [ class "cmdLog" ]
                    <| List.map (\log -> pre [] [text log]) model.cmdLog
                , div []
                    [ Html.form [ onSubmit SendCommand ]
                        [ button [ class "rightButton" ] [text "Send command"]
                        , span [ class "wrapper" ] 
                            [ input [ class "cmdInp"
                                    , placeholder "DENY * view"
                                    , onInput UpdateText
                                    , value cmd ] [] 
                            ]
                        
                        ]
                    , button [ onClick ClosePopup ] [text "Done"]
                    , button [ onClick ClearLogs ] [text "Clear"]
                    ]
                ]
            ]



subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Window.resizes Resize
        , Time.every (Time.second / 30) UpdateClient
        , Mouse.downs MousePress
        , Mouse.ups MouseRelease
        , Mouse.moves MouseMove
        , Keyboard.downs KeyCodeDown
        , Keyboard.ups KeyCodeUp
        , WebSocket.listen model.webSocketUrl ServerSync
        ]